import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { ArtifactStore } from '../node_modules/@azure-tools/apiops-cli/dist/clients/artifact-store.js';
import { loadOverrideConfig } from '../node_modules/@azure-tools/apiops-cli/dist/lib/config-loader.js';
import { runPublish } from '../node_modules/@azure-tools/apiops-cli/dist/services/publish-service.js';
import { logger } from '../node_modules/@azure-tools/apiops-cli/dist/lib/logger.js';
import {
  configFrom, configKeys, regionsFrom, overridesFor, sourceSnapshot, expectedResources, compareResources,
  assertPrivacy, deletionResources, assertPlan, hash, lifecycle, project, verifyRuntime,
  applyDeletions, productionAdapter,
} from '../scripts/apiops.mjs';

logger.configure({ level: 'ERROR' });

const sourceDir = fileURLToPath(new URL('../apim-artifacts', import.meta.url));

for (const [region, ip] of [['westus2', '10.10.3.250'], ['eastus', '10.20.3.250']]) {
  test(`pinned APIOps publisher reads and publishes every artifact with ${region} overrides`, async () => {
    const directory = await mkdtemp(join(tmpdir(), 'apiops-test-'));
    try {
      const path = join(directory, 'configuration.json');
      await writeFile(path, JSON.stringify({
        namedValues: [
          { name: 'poc-front-door-id', properties: { value: 'test-fdid' } },
          { name: 'poc-region', properties: { value: region } },
        ],
        apis: [{ name: 'regional-demo', properties: { serviceUrl: `http://${ip}` } }],
      }));
      const writes = [];
      const client = {
        async validatePreFlight() {},
        async getResource() { return undefined; },
        async putResource(context, descriptor, body) { writes.push({ descriptor, body }); },
      };
      const result = await runPublish(client, new ArtifactStore(), {
        service: { subscriptionId: 'test', resourceGroup: 'test', serviceName: 'test' },
        sourceDir, overrides: await loadOverrideConfig(path), dryRun: false, deleteUnmatched: false,
      });
      assert.equal(result.exitCode, 0);
      assert.equal(result.totalErrors, 0);
      assert.equal(writes.length, 6);
      const api = writes.find(write => write.descriptor.type === 'Api').body.properties;
      assert.equal(api.serviceUrl, `http://${ip}`);
      assert.equal(api.path, 'demo');
      assert.deepEqual(api.protocols, ['https']);
      assert.equal(api.subscriptionRequired, false);
      const operations = writes.filter(write => write.descriptor.type === 'ApiOperation');
      assert.deepEqual(operations.map(write => write.body.properties.urlTemplate).sort(), ['/', '/health/ready']);
      assert.ok(operations.every(write => write.body.properties.method === 'GET'));
      for (const [name, value] of [['poc-region', region], ['poc-front-door-id', 'test-fdid']]) {
        const index = writes.findIndex(write => write.descriptor.nameParts[0] === name);
        assert.equal(writes[index].body.properties.value, value);
        assert.ok(index < writes.findIndex(write => write.descriptor.type === 'Api'));
      }

      const policy = writes.find(write => write.descriptor.type === 'ApiPolicy').body.properties.value;
      assert.ok(policy.includes('{{poc-front-door-id}}'));
      assert.ok(policy.includes('{{poc-region}}'));
      assert.ok(policy.includes('X-Correlation-ID'));
      assert.ok(policy.includes('no-store'));
    } finally {
      await rm(directory, { recursive: true });
    }
  });
}

const subscription = '00000000-0000-0000-0000-000000000001';
function configuration() {
  const config = {
    AZURE_ENV_NAME: 'test', AZURE_SUBSCRIPTION_ID: subscription, AZURE_RESOURCE_GROUP: 'global',
    FRONT_DOOR_PROFILE_NAME: 'profile', FRONT_DOOR_ID: subscription, FRONT_DOOR_ORIGIN_GROUP_NAME: 'origins',
    API_URL: 'https://test.azurefd.net/demo/', API_HEALTH_URL: 'https://test.azurefd.net/demo/health/ready',
  };
  for (const [prefix, location, ip] of [['BRAZIL', 'westus2', '10.10.3.250'], ['US', 'eastus', '10.20.3.250']]) {
    Object.assign(config, {
      [`${prefix}_RESOURCE_GROUP`]: prefix, [`${prefix}_APIM_NAME`]: `apim-${prefix}`,
      [`${prefix}_APIM_ID`]: `/subscriptions/${subscription}/resourceGroups/${prefix}/providers/Microsoft.ApiManagement/service/apim-${prefix}`,
      [`${prefix}_AKS_NAME`]: `aks-${prefix}`, [`${prefix}_LOCATION`]: location,
      [`${prefix}_BACKEND_IP`]: ip, [`${prefix}_APIM_SUBNET`]: '10.10.4.0/24',
    });
  }
  return config;
}
function fixture(config = configuration()) {
  const state = new Map();
  const calls = [];
  const adapter = {
    calls, state, sleep: async () => {},
    client: {
      async validatePreFlight() {},
      async getResource(context, descriptor) { return structuredClone(state.get(`${context.serviceName}/${descriptor.type}/${descriptor.nameParts.join('/')}`)); },
      async putResource(context, descriptor, body) {
        calls.push(`put:${context.serviceName}`);
        state.set(`${context.serviceName}/${descriptor.type}/${descriptor.nameParts.join('/')}`, structuredClone(body));
      },
      async deleteResource(context, descriptor) {
        calls.push(`delete:${descriptor.nameParts.join('/')}`);
        state.delete(`${context.serviceName}/${descriptor.type}/${descriptor.nameParts.join('/')}`);
      },
      async *listResources(context, type, parent) {
        const prefix = `${context.serviceName}/${type}/${parent.nameParts[0]}/`;
        for (const [key, body] of state) {
          if (key.startsWith(prefix)) yield { name: key.split('/').at(-1), properties: body.properties };
        }
      },
    },
    async arm(method, id) {
      assert.equal(method, 'GET', 'privacy/plan must never modify infrastructure');
      calls.push(`privacy:${id}`);
      const region = regionsFrom(config).find(region => id.includes(region.id));
      if (id.endsWith('/privateEndpointConnections')) {
        return { value: [{ properties: { privateLinkServiceConnectionState: {
          status: 'Approved', description: `azd:test:${region.key}:profile`,
        } } }] };
      }
      if (id.includes('/origins/')) {
        const key = id.split('/').at(-1);
        const target = regionsFrom(config).find(region => region.key === key);
        return { properties: { sharedPrivateLinkResource: {
          privateLink: { id: target.id }, groupId: 'Gateway', requestMessage: `azd:test:${key}:profile`,
        } } };
      }
      return { properties: { publicNetworkAccess: 'Disabled' } };
    },
    async publish(region, source, values) {
      calls.push(`publish:${region.key}`);
      return runPublish(adapter.client, new ArtifactStore(), {
        service: region.context, sourceDir: source.directory, overrides: overridesFor(values, region),
        dryRun: false, deleteUnmatched: false,
      });
    },
    async backend(values, region) { calls.push(`backend:${region.key}`); },
    async http(url) {
      if (url.includes('azure-api.net')) {
        const name = new URL(url).hostname.split('.')[0];
        return { status: 403, body: { statusCode: 403, message: `public network access on ${name} is disabled` } };
      }
      return {
        status: 200, body: url.endsWith('health/ready') ? { status: 'ok', region: 'eastus' } : { service: 'regional-demo', region: 'eastus' },
        headers: { 'x-served-region': 'eastus', 'x-correlation-id': subscription, 'cache-control': 'no-store' },
      };
    },
  };
  return adapter;
}

test('configuration export is allowlisted, validated and contains no credentials', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'apiops-config-'));
  try {
    const config = { ...configuration(), AZURE_CLIENT_SECRET: 'do-not-export', OTHER_VALUE: 'private' };
    const output = join(directory, 'configuration.json');
    const adapter = fixture();
    const result = await lifecycle({ action: 'export', config, output }, adapter);
    assert.equal(result.status, 'exported');
    const exported = JSON.parse(await readFile(output));
    assert.deepEqual(Object.keys(exported).sort(), [...configKeys].sort());
    assert.equal((await readFile(output, 'utf8')).includes('do-not-export'), false);
    assert.equal(adapter.calls.length, 0);
    for (const change of [
      { US_APIM_ID: config.BRAZIL_APIM_ID }, { US_BACKEND_IP: '10.20.3.999' },
      { AZURE_SUBSCRIPTION_ID: '' }, { API_URL: 'http://example.test/demo/' },
      { US_APIM_SUBNET: 'not-a-subnet' }, { US_APIM_SUBNET: '10.20.4.0/33' },
      { FRONT_DOOR_ID: 'not-a-guid' },
    ]) assert.throws(() => configFrom({ ...config, ...change }));
  } finally { await rm(directory, { recursive: true }); }
});

test('real CLI stdin and PowerShell file input export validated configuration without Azure calls', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'apiops-cli-'));
  try {
    const config = { ...configuration(), AZURE_CLIENT_SECRET: 'do-not-export' };
    const output = join(directory, 'configuration.json');
    const engine = fileURLToPath(new URL('../scripts/apiops.mjs', import.meta.url));
    const stdout = execFileSync(process.execPath, [engine, '--config', '-', '--action', 'export', '--output', output], {
      input: JSON.stringify(config), encoding: 'utf8',
    });
    assert.match(stdout, /configuration exported/);
    assert.deepEqual(JSON.parse(await readFile(output)), configFrom(config));
    if (process.platform === 'win32') {
      const script = fileURLToPath(new URL('../scripts/ps1/Sync-Apim.ps1', import.meta.url));
      const input = join(directory, 'input.json');
      await writeFile(input, JSON.stringify(config));
      execFileSync('pwsh', ['-NoProfile', '-File', script, '-Action', 'Export', '-ConfigPath', input, '-OutputPath', output]);
      assert.deepEqual(JSON.parse(await readFile(output)), configFrom(config));
    }
  } finally { await rm(directory, { recursive: true }); }
});

test('preview is read-only, binds inputs and both live baselines, and publish verifies both regional configurations', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'apiops-plan-'));
  try {
    const config = configuration();
    const adapter = fixture(config);
    const plan = join(directory, 'plan.json');
    const report = join(directory, 'report.json');
    const preview = await lifecycle({ action: 'plan', config, plan, report }, adapter);
    assert.equal(preview.status, 'planned');
    assert.equal(preview.regions.length, 2);
    assert.ok(preview.regions.every(region => region.comparison.length === 6));
    assert.equal(adapter.calls.some(call => call.startsWith('put:') || call.startsWith('backend:')), false);
    assert.equal((await readFile(plan, 'utf8')).includes(config.BRAZIL_BACKEND_IP), false);
    const comparisons = preview.regions.map(region => region.comparison);
    for (const key of ['commit', 'artifactHash', 'configurationHash', 'deletionHash', 'toolHash']) {
      assert.throws(() => assertPlan({ ...preview, [key]: 'changed' }, preview, comparisons), /does not match/);
    }
    assert.throws(() => assertPlan({ ...preview, createdAt: '2020-01-01' }, preview, comparisons), /expired/);
    const now = Date.now();
    assert.doesNotThrow(() => assertPlan({ ...preview, createdAt: new Date(now - 86400000).toISOString() }, preview, comparisons, now));
    assert.throws(() => assertPlan({ ...preview, createdAt: new Date(now - 86400001).toISOString() }, preview, comparisons, now), /expired/);
    assert.throws(() => assertPlan(preview, preview, []), /changed after preview/);
    const published = await lifecycle({ action: 'publish', config, plan, report }, adapter);
    assert.equal(published.status, 'verified');
    assert.ok(published.regions.every(region => region.status === 'verified-configuration'));
    assert.deepEqual(published.runtime.observedFrontDoorRegions, ['eastus']);
    assert.match(published.runtime.gatewayCoverage, /not proven/);
    assert.ok(adapter.calls.indexOf('publish:br') > adapter.calls.findLastIndex(call => call.startsWith('privacy:')));
    const disk = JSON.parse(await readFile(report));
    assert.equal(disk.status, 'verified');
    assert.ok(disk.completedAt);
    assert.ok(disk.regions.every(region => region.durationMs >= 0));
    const drift = await lifecycle({ action: 'drift', config, report }, adapter);
    assert.equal(drift.status, 'matching');
    const resourceKey = `apim-US/Api/regional-demo`;
    adapter.state.get(resourceKey).properties.serviceUrl = 'http://wrong';
    const changed = await lifecycle({ action: 'drift', config, report }, adapter);
    assert.equal(changed.status, 'drifted');
    assert.equal(changed.regions[1].comparison.find(resource => resource.path === 'apis/regional-demo').status, 'changed');
    adapter.state.set('apim-US/ApiOperation/regional-demo/portal-operation', { properties: {
      displayName: 'Portal-only operation', method: 'GET', urlTemplate: '/portal',
    } });
    const extra = await lifecycle({ action: 'drift', config, report }, adapter);
    assert.equal(extra.regions[1].comparison.find(resource => resource.path.endsWith('/portal-operation')).status, 'unmanaged');
    assert.ok(adapter.state.has('apim-US/ApiOperation/regional-demo/portal-operation'));
    const before = adapter.calls.filter(call => call.startsWith('publish:')).length;
    await assert.rejects(lifecycle({ action: 'publish', config, plan, report }, adapter), /changed after preview/);
    assert.equal(adapter.calls.filter(call => call.startsWith('publish:')).length, before);
  } finally { await rm(directory, { recursive: true }); }
});

test('failure on the second APIM persists honest partial evidence and a full retry recovers', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'apiops-partial-'));
  try {
    const config = configuration();
    const adapter = fixture(config);
    const publish = adapter.publish;
    adapter.publish = async (...args) => args[0].key === 'us'
      ? { exitCode: 1, totalErrors: 1, actions: [] } : publish(...args);
    const report = join(directory, 'report.json');
    await assert.rejects(lifecycle({ action: 'publish', config, report }, adapter), /publication failed/);
    const failed = JSON.parse(await readFile(report));
    assert.equal(failed.status, 'failed');
    assert.equal(failed.failedStage, 'publish:us');
    assert.deepEqual(failed.regions.map(region => region.status), ['verified-configuration', 'failed']);
    assert.equal(failed.runtime, undefined);
    adapter.publish = publish;
    const recovered = await lifecycle({ action: 'publish', config, report }, adapter);
    assert.equal(recovered.status, 'verified');
  } finally { await rm(directory, { recursive: true }); }
});

test('privacy failure on either APIM blocks every publish and is reported', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'apiops-private-'));
  try {
    for (const condition of ['public', 'wrong-origin', 'wrong-marker', 'ambiguous']) {
      const config = configuration();
      const adapter = fixture(config);
      const arm = adapter.arm;
      adapter.arm = async (...args) => {
        const value = await arm(...args);
        if (condition === 'public' && args[1] === config.US_APIM_ID) value.properties.publicNetworkAccess = 'Enabled';
        if (condition === 'wrong-origin' && args[1].endsWith('/origins/us')) value.properties.sharedPrivateLinkResource.groupId = 'wrong';
        if (args[1].endsWith('/privateEndpointConnections')) {
          if (condition === 'wrong-marker') value.value[0].properties.privateLinkServiceConnectionState.description = 'someone-else';
          if (condition === 'ambiguous') value.value.push(structuredClone(value.value[0]));
        }
        return value;
      };
      const report = join(directory, 'report.json');
      await assert.rejects(lifecycle({ action: 'publish', config, report }, adapter));
      assert.equal(adapter.calls.some(call => call.startsWith('publish:')), false);
      assert.equal(JSON.parse(await readFile(report)).failedStage, 'preflight');
    }
  } finally { await rm(directory, { recursive: true }); }
});

test('drift projection ignores server defaults but detects missing routes, policies and regional overrides', () => {
  assert.deepEqual(project({ responses: [{ statusCode: 200 }] }, { responses: [{ statusCode: 200, description: 'OK' }], provisioningState: 'Succeeded' }),
    { responses: [{ statusCode: 200 }] });
  assert.equal(hash(project({ value: '<policies>\n <inbound />\n</policies>' }, { value: '<policies><inbound /></policies>' })),
    hash(project({ value: '<policies>\n <inbound />\n</policies>' }, { value: '<policies>\r\n<inbound /></policies>' })));
  const expected = { value: '<policies><inbound><set-header name="a" exists-action="override"><value>x</value></set-header></inbound></policies>' };
  assert.equal(hash(project(expected, expected)), hash(project(expected, {
    value: '<policies>\n<inbound><!-- no functional change --><set-header exists-action="override" name="a"><value>x</value></set-header></inbound></policies>',
  })));
  assert.notEqual(hash(project(expected, expected)), hash(project(expected, {
    value: '<policies><inbound><set-header name="a" exists-action="override"><value>y</value></set-header></inbound></policies>',
  })));
  assert.throws(() => project(expected, { value: '<policies><inbound></policies>' }), /Malformed policy XML/);
});

test('rollback reads only artifact files at a full SHA and retains present-day regional overrides', async () => {
  const current = await sourceSnapshot();
  let rollback;
  try {
    rollback = await sourceSnapshot(current.commit);
    assert.equal(rollback.commit, current.commit);
    const config = configuration();
    config.US_BACKEND_IP = '10.20.3.240';
    const resources = await expectedResources(rollback, config, regionsFrom(config)[1]);
    assert.equal(resources.find(resource => resource.path === 'apis/regional-demo').properties.serviceUrl, 'http://10.20.3.240');
    await assert.rejects(sourceSnapshot('main'), /full lowercase/);
    await assert.rejects(sourceSnapshot('54f60ef6' + '0'.repeat(32)));
  } finally {
    await rm(current.directory, { recursive: true });
    if (rollback) await rm(rollback.directory, { recursive: true });
  }
});

test('deletion manifests permit only absent, previously owned, noncritical explicit operations', async () => {
  const source = { files: [] };
  const resources = [{ path: 'apis/regional-demo' }];
  const base = { schemaVersion: 1, baseRevision: 'a'.repeat(40), operations: [
    { path: 'apis/regional-demo/operations/old-status', reason: 'Remove retired status operation' },
  ] };
  const reads = [];
  const deletions = await deletionResources(base, source, resources, args => reads.push(args));
  assert.equal(deletions.length, 1);
  assert.equal(deletions[0].descriptor.type, 'ApiOperation');
  assert.match(reads[0][2], /operationInformation.json/);
  for (const path of ['apis/regional-demo/operations/ready', 'apis/regional-demo/operations/region',
    'apis/regional-demo', 'namedValues/token', 'apis/unknown/operations/retired', '../operations/old-status']) {
    await assert.rejects(deletionResources({ ...base, operations: [{ ...base.operations[0], path }] }, source, resources, () => {}));
  }
  await assert.rejects(deletionResources(base, source, [...resources, { path: base.operations[0].path }], () => {}), /absent/);
  await assert.rejects(deletionResources(base, source, resources, () => { throw new Error('not in base commit'); }), /not in base/);
  await assert.rejects(lifecycle({ action: 'publish', config: configuration(), allowDelete: true }, fixture()), /explicit preview plan/);
});

test('runtime verification checks regional backends, public blocking and Front Door contracts without claiming both observations', async () => {
  const config = configuration();
  const adapter = fixture();
  const result = await verifyRuntime(adapter, config, regionsFrom(config));
  assert.deepEqual(result.observedFrontDoorRegions, ['eastus']);
  assert.deepEqual(adapter.calls, ['backend:br', 'backend:us']);
  const http = adapter.http;
  adapter.http = async (...args) => {
    const result = await http(...args);
    if (result.headers) result.headers['x-correlation-id'] = 'not-a-guid';
    return result;
  };
  await assert.rejects(verifyRuntime(adapter, config, regionsFrom(config)), /runtime contract/);
  assert.deepEqual(adapter.calls, ['backend:br', 'backend:us', 'backend:br', 'backend:us']);
});

test('only explicit deletion descriptors are executed and absence is verified idempotently', async () => {
  const config = configuration();
  const adapter = fixture();
  const region = regionsFrom(config)[0];
  const descriptor = { type: 'ApiOperation', nameParts: ['regional-demo', 'retired'] };
  const deletions = [{ path: 'apis/regional-demo/operations/retired', descriptor }];
  adapter.state.set('apim-BRAZIL/ApiOperation/regional-demo/retired', { properties: { method: 'GET' } });
  adapter.state.set('apim-BRAZIL/ApiOperation/regional-demo/other', { properties: { method: 'GET' } });
  await applyDeletions(adapter.client, region, deletions);
  await applyDeletions(adapter.client, region, deletions);
  assert.equal(adapter.state.has('apim-BRAZIL/ApiOperation/regional-demo/retired'), false);
  assert.ok(adapter.state.has('apim-BRAZIL/ApiOperation/regional-demo/other'));
  adapter.client.getResource = async () => ({ properties: {} });
  await assert.rejects(applyDeletions(adapter.client, region, deletions), /Deletion did not verify/);
});

test('approved deletion lifecycle removes only the named operation from both APIMs and can be retried', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'apiops-delete-'));
  try {
    const config = configuration();
    const adapter = fixture(config);
    adapter.readGit = args => {
      assert.deepEqual(args, ['cat-file', '-e',
        `${'a'.repeat(40)}:apim-artifacts/apis/regional-demo/operations/retired/operationInformation.json`]);
      return '';
    };
    const deletions = join(directory, 'deletions.json');
    await writeFile(deletions, JSON.stringify({
      schemaVersion: 1, baseRevision: 'a'.repeat(40),
      operations: [{ path: 'apis/regional-demo/operations/retired', reason: 'Remove the retired test operation' }],
    }));
    for (const region of regionsFrom(config)) {
      for (const name of ['retired', 'other']) {
        adapter.state.set(`${region.name}/ApiOperation/regional-demo/${name}`, {
          properties: { displayName: name, method: 'GET', urlTemplate: `/${name}` },
        });
      }
    }
    const options = { config, deletions, plan: join(directory, 'plan.json'), report: join(directory, 'report.json') };
    for (let attempt = 0; attempt < 2; attempt++) {
      const plan = await lifecycle({ ...options, action: 'plan' }, adapter);
      for (const region of plan.regions) {
        const planned = region.comparison.filter(resource => resource.path.endsWith('/retired'));
        assert.equal(planned.length, 1);
        assert.equal(planned[0].status, attempt === 0 ? 'delete' : 'absent');
      }
      const writes = adapter.calls.filter(call => call.startsWith('put:') || call.startsWith('delete:')).length;
      await assert.rejects(lifecycle({ ...options, action: 'publish' }, adapter), /requires --allow-delete/);
      assert.equal(adapter.calls.filter(call => call.startsWith('put:') || call.startsWith('delete:')).length, writes);
      const published = await lifecycle({ ...options, action: 'publish', allowDelete: true }, adapter);
      assert.equal(published.status, 'verified');
      for (const region of regionsFrom(config)) {
        assert.equal(adapter.state.has(`${region.name}/ApiOperation/regional-demo/retired`), false);
        assert.ok(adapter.state.has(`${region.name}/ApiOperation/regional-demo/other`));
      }
    }
    assert.equal(adapter.calls.filter(call => call === 'delete:regional-demo/retired').length, 4);
  } finally { await rm(directory, { recursive: true }); }
});

test('runtime failure is persisted as failed even when both configurations published successfully', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'apiops-runtime-'));
  try {
    const adapter = fixture();
    adapter.backend = async () => { throw new Error('sensitive raw response'); };
    const report = join(directory, 'report.json');
    await assert.rejects(lifecycle({ action: 'publish', config: configuration(), report }, adapter), /sensitive raw response/);
    const raw = await readFile(report, 'utf8');
    const saved = JSON.parse(raw);
    assert.equal(saved.status, 'failed');
    assert.equal(saved.failedStage, 'runtime-verification');
    assert.equal(saved.runtime.status, 'failed');
    assert.ok(saved.regions.every(region => region.status === 'verified-configuration'));
    assert.equal(raw.includes('sensitive raw response'), false);
  } finally { await rm(directory, { recursive: true }); }
});

test('production ARM errors retain HTTP status without exposing response bodies to publisher logs', async t => {
  const adapter = productionAdapter();
  t.mock.method(adapter.client, 'getToken', async () => 'test-token');
  t.mock.method(globalThis, 'fetch', async () => new Response(JSON.stringify({
    error: { code: 'ValidationError', message: 'sensitive artifact value' },
  }), { status: 400 }));
  await assert.rejects(adapter.client.request('https://management.azure.com/test', { method: 'PUT' }), error => {
    assert.equal(error.status, 400);
    assert.equal(error.code, 'ValidationError');
    assert.equal(error.body, undefined);
    assert.equal(error.message.includes('sensitive artifact value'), false);
    return true;
  });
});

test('the production backend adapter uses scoped AKS Run Command and checks the final exit code', async () => {
  const config = configuration();
  const region = regionsFrom(config)[0];
  const adapter = productionAdapter(async () => {});
  const calls = [];
  let exitCode = 0;
  adapter.client.credential = { async getToken(scope) {
    assert.equal(scope, '6dae42f8-4368-4678-94ff-3960e28e3630/.default');
    return { token: 'test-token' };
  } };
  const clusterId = `/subscriptions/${subscription}/resourceGroups/BRAZIL/providers/Microsoft.ContainerService/managedClusters/aks-BRAZIL`;
  adapter.client.request = async (url, options) => {
    calls.push({ url, options });
    if (url.includes('/runCommand?')) {
      const body = JSON.parse(options.body);
      assert.equal(body.clusterToken, 'test-token');
      assert.ok(body.command.includes('kubectl -n private-poc exec deployment/regional-demo'));
      assert.ok(body.command.includes('http://10.10.3.250/health/ready'));
      return { status: 202, headers: new Headers({ Location: `https://management.azure.com${clusterId}/commandResults/result?api-version=2025-01-01` }) };
    }
    return { ok: true, json: async () => ({ properties: { provisioningState: 'Succeeded', exitCode } }) };
  };
  await adapter.backend(config, region);
  assert.equal(calls.length, 2);
  exitCode = 2;
  await assert.rejects(adapter.backend(config, region), /Regional backend verification failed/);
  adapter.client.request = async () => ({ status: 202, headers: new Headers({ Location: 'https://other.invalid/result' }) });
  await assert.rejects(adapter.backend(config, region), /Unexpected AKS command result URL/);
});
