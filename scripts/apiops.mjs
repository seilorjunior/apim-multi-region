import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { isIPv4 } from 'node:net';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { DOMParser } from '@xmldom/xmldom';
import { ArtifactStore } from '../node_modules/@azure-tools/apiops-cli/dist/clients/artifact-store.js';
import { ApimClient, HttpError } from '../node_modules/@azure-tools/apiops-cli/dist/clients/apim-client.js';
import { buildResourceLabel } from '../node_modules/@azure-tools/apiops-cli/dist/lib/resource-uri.js';
import { runPublish } from '../node_modules/@azure-tools/apiops-cli/dist/services/publish-service.js';
import { logger } from '../node_modules/@azure-tools/apiops-cli/dist/lib/logger.js';

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const version = '2024-05-01';
const prefixes = ['BRAZIL', 'US'];
export const configKeys = [
  'AZURE_ENV_NAME', 'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP',
  'FRONT_DOOR_PROFILE_NAME', 'FRONT_DOOR_ID', 'FRONT_DOOR_ORIGIN_GROUP_NAME',
  'API_URL', 'API_HEALTH_URL',
  ...prefixes.flatMap(prefix => ['RESOURCE_GROUP', 'APIM_NAME', 'APIM_ID', 'AKS_NAME',
    'BACKEND_IP', 'APIM_SUBNET', 'LOCATION'].map(suffix => `${prefix}_${suffix}`)),
];
const supported = new Set(['Api', 'ApiOperation', 'ApiPolicy', 'ApiOperationPolicy', 'NamedValue', 'Backend']);
const guid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const sha = /^[a-f0-9]{40}$/;
const namePattern = /^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/;
const sleep = ms => new Promise(resolveSleep => setTimeout(resolveSleep, ms));
class LifecycleError extends Error {}
class LifecycleApimClient extends ApimClient {
  async request(...args) {
    try {
      return await super.request(...args);
    } catch (error) {
      // The publisher logs exception messages; ARM bodies can contain artifact values.
      if (error instanceof HttpError) throw new HttpError(error.status, `Azure request failed with HTTP ${error.status}.`, error.code);
      throw new LifecycleError('Azure authentication or transport failed. Inspect Azure operation results.');
    }
  }
}
const canonical = value => JSON.stringify(sort(value));
function sort(value) {
  if (Array.isArray(value)) return value.map(sort);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, sort(value[key])]));
  }
  return value;
}
export const hash = value => createHash('sha256').update(canonical(value)).digest('hex');
function requireThat(condition, message) {
  if (!condition) throw new LifecycleError(message);
}
export function configFrom(values) {
  requireThat(values && typeof values === 'object' && !Array.isArray(values), 'Configuration must be a JSON object.');
  const config = {};
  for (const key of configKeys) {
    requireThat(typeof values[key] === 'string' && values[key].trim() !== '', `Missing configuration key: ${key}. Export a provisioned azd environment.`);
    config[key] = values[key];
  }
  requireThat(guid.test(config.AZURE_SUBSCRIPTION_ID) && !/^0{8}-0{4}-0{4}-0{4}-0{12}$/.test(config.AZURE_SUBSCRIPTION_ID), 'Invalid subscription GUID.');
  requireThat(guid.test(config.FRONT_DOOR_ID), 'Invalid Front Door ID GUID.');
  for (const key of ['AZURE_ENV_NAME', 'AZURE_RESOURCE_GROUP', 'FRONT_DOOR_PROFILE_NAME', 'FRONT_DOOR_ORIGIN_GROUP_NAME']) {
    requireThat(namePattern.test(config[key]), `Invalid resource name: ${key}.`);
  }
  for (const prefix of prefixes) {
    for (const suffix of ['RESOURCE_GROUP', 'APIM_NAME', 'AKS_NAME', 'LOCATION']) {
      requireThat(namePattern.test(config[`${prefix}_${suffix}`]), `Invalid resource name: ${prefix}_${suffix}.`);
    }
    const ip = config[`${prefix}_BACKEND_IP`];
    requireThat(isIPv4(ip), `Invalid backend IPv4 address: ${prefix}.`);
    const subnet = config[`${prefix}_APIM_SUBNET`].split('/');
    requireThat(subnet.length === 2 && isIPv4(subnet[0]) && /^(?:[0-9]|[12][0-9]|3[0-2])$/.test(subnet[1]),
      `Invalid APIM subnet CIDR: ${prefix}.`);
    const expected = `/subscriptions/${config.AZURE_SUBSCRIPTION_ID}/resourceGroups/${config[`${prefix}_RESOURCE_GROUP`]}/providers/Microsoft.ApiManagement/service/${config[`${prefix}_APIM_NAME`]}`;
    requireThat(config[`${prefix}_APIM_ID`].toLowerCase() === expected.toLowerCase(), `APIM ID/name/group/subscription mismatch: ${prefix}.`);
  }
  requireThat(config.BRAZIL_APIM_ID.toLowerCase() !== config.US_APIM_ID.toLowerCase(), 'Both targets must be distinct APIM instances.');
  for (const key of ['API_URL', 'API_HEALTH_URL']) {
    const url = new URL(config[key]);
    requireThat(url.protocol === 'https:' && !url.username && !url.password && !url.search && !url.hash, `Expected a credential-free HTTPS URL: ${key}.`);
  }
  requireThat(config.API_HEALTH_URL === `${config.API_URL}health/ready` && new URL(config.API_URL).pathname === '/demo/', 'Expected matching /demo/ and /demo/health/ready URLs.');
  return config;
}
export function regionsFrom(config) {
  return prefixes.map((prefix, index) => ({
    key: index === 0 ? 'br' : 'us', location: config[`${prefix}_LOCATION`],
    id: config[`${prefix}_APIM_ID`], name: config[`${prefix}_APIM_NAME`],
    group: config[`${prefix}_RESOURCE_GROUP`], cluster: config[`${prefix}_AKS_NAME`],
    backend: config[`${prefix}_BACKEND_IP`],
    context: {
      subscriptionId: config.AZURE_SUBSCRIPTION_ID, resourceGroup: config[`${prefix}_RESOURCE_GROUP`],
      serviceName: config[`${prefix}_APIM_NAME`], apiVersion: version,
      baseUrl: `https://management.azure.com${config[`${prefix}_APIM_ID`]}`,
    },
  }));
}
export function overridesFor(config, region) {
  return {
    namedValues: {
      'poc-front-door-id': { properties: { value: config.FRONT_DOOR_ID } },
      'poc-region': { properties: { value: region.location } },
    },
    apis: { 'regional-demo': { properties: { serviceUrl: `http://${region.backend}` } } },
  };
}
function git(args) {
  return execFileSync('git', args, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 32 * 1024 * 1024 }).trimEnd();
}
async function filesUnder(directory) {
  const files = [];
  for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
    requireThat(!entry.isSymbolicLink(), 'Artifact symlinks are not supported.');
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await filesUnder(path));
    else files.push(path);
  }
  return files;
}
export async function sourceSnapshot(revision) {
  const commit = revision || git(['rev-parse', 'HEAD']);
  requireThat(sha.test(commit), 'Revision must be a full lowercase 40-character commit SHA.');
  git(['cat-file', '-e', `${commit}^{commit}`]);
  const directory = await mkdtemp(join(tmpdir(), 'apiops-source-'));
  try {
    if (revision) {
      const paths = git(['ls-tree', '-r', '--name-only', commit, '--', 'apim-artifacts']).split('\n').filter(Boolean);
      requireThat(paths.length > 0, 'Revision has no APIOps artifacts; rollback to pre-APIOps Bicep revisions is not supported.');
      for (const path of paths) {
        requireThat(path.startsWith('apim-artifacts/') && !path.includes('..'), 'Invalid Git artifact path.');
        const target = join(directory, path.slice('apim-artifacts/'.length));
        await mkdir(dirname(target), { recursive: true });
        await writeFile(target, git(['show', `${commit}:${path}`]), 'utf8');
      }
    } else {
      for (const path of await filesUnder(join(root, 'apim-artifacts'))) {
        const target = join(directory, relative(join(root, 'apim-artifacts'), path));
        await mkdir(dirname(target), { recursive: true });
        await writeFile(target, await readFile(path));
      }
    }
    const files = [];
    for (const path of await filesUnder(directory)) {
      files.push([relative(directory, path).replaceAll('\\', '/'), (await readFile(path, 'utf8')).replaceAll('\r\n', '\n').trimEnd()]);
    }
    return { commit, directory, artifactHash: hash(files), files };
  } catch (error) {
    await rm(directory, { recursive: true });
    throw error;
  }
}
export async function expectedResources(source, config, region, store = new ArtifactStore()) {
  const descriptors = await store.listResources(source.directory);
  requireThat(descriptors.length > 0, 'Artifact set is empty.');
  const resources = [];
  for (const descriptor of descriptors) {
    requireThat(supported.has(descriptor.type) && !descriptor.workspace, `Unsupported lifecycle resource: ${descriptor.type}. Extend verification before publishing it.`);
    requireThat(descriptor.nameParts.every(part => namePattern.test(part)), 'Unsupported artifact resource name or revision.');
    let properties;
    if (descriptor.type.endsWith('Policy')) {
      properties = { value: (await store.readContent(source.directory, descriptor, 'policy')).content };
    } else {
      properties = (await store.readResource(source.directory, descriptor)).properties;
      requireThat(properties && !properties.secret && !properties.keyVault && !properties.credentials,
        'Secret/key-vault/credential artifacts require an explicit verification implementation; they are not exported or compared.');
      if (descriptor.type === 'Api') {
        requireThat(!await store.readContent(source.directory, descriptor, 'specification'), 'Specification imports are not yet supported by lifecycle verification; use explicit operations.');
      }
    }
    const override = overridesFor(config, region);
    if (descriptor.type === 'Api') properties = { ...properties, ...override.apis[descriptor.nameParts[0]]?.properties };
    if (descriptor.type === 'NamedValue') properties = { ...properties, ...override.namedValues[descriptor.nameParts[0]]?.properties };
    resources.push({ descriptor, path: buildResourceLabel(descriptor), properties });
  }
  requireThat(resources.some(resource => resource.path === 'apis/regional-demo') &&
    ['region', 'ready'].every(name => resources.some(resource => resource.path === `apis/regional-demo/operations/${name}`)),
  'The demo API and required root/readiness operations must remain present.');
  return resources.sort((a, b) => a.path.localeCompare(b.path));
}
function normalizeXml(value) {
  const document = new DOMParser({
    onError() { throw new LifecycleError('Malformed policy XML.'); },
  }).parseFromString(value.replaceAll('\r\n', '\n'), 'application/xml');
  function nodeValue(node) {
    if (node.nodeType === 1) {
      const children = [...node.childNodes];
      const hasElements = children.some(child => child.nodeType === 1);
      return [
        node.nodeName,
        [...node.attributes].map(attribute => [attribute.name, attribute.value]).sort(([a], [b]) => a.localeCompare(b)),
        children.filter(child => child.nodeType !== 8 && !(hasElements && child.nodeType === 3 && !child.data.trim())).map(nodeValue),
      ];
    }
    return node.data ?? '';
  }
  return canonical(nodeValue(document.documentElement));
}
export function project(expected, actual) {
  if (typeof expected === 'string' && expected.trimStart().startsWith('<policies')) {
    return typeof actual === 'string' ? normalizeXml(actual) : null;
  }
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual) || actual.length !== expected.length) return actual ?? null;
    const identity = item => item && typeof item === 'object' ? item.statusCode ?? item.name ?? item.value : item;
    return expected.map((item, index) => project(item, identity(item) === undefined
      ? actual[index] : actual.find(candidate => identity(candidate) === identity(item))));
  }
  if (expected && typeof expected === 'object') {
    return Object.fromEntries(Object.entries(expected).map(([key, value]) => [key, project(value, actual?.[key])]));
  }
  return actual ?? null;
}
export async function compareResources(client, region, resources) {
  const results = [];
  const existingApis = [];
  for (const resource of resources) {
    const actual = await client.getResource(region.context, resource.descriptor);
    if (actual && resource.descriptor.type === 'Api') existingApis.push(resource.descriptor);
    const expected = project(resource.properties, resource.properties);
    const observed = actual ? project(resource.properties, actual.properties) : null;
    results.push({
      path: resource.path, status: !actual ? 'missing' : canonical(expected) === canonical(observed) ? 'matching' : 'changed',
      expectedHash: hash(expected), observedHash: hash(observed),
    });
  }
  for (const api of existingApis) {
    for await (const operation of client.listResources(region.context, 'ApiOperation', api)) {
      const path = `apis/${api.nameParts[0]}/operations/${operation.name.split('/').at(-1)}`;
      if (!resources.some(resource => resource.path === path)) {
        results.push({ path, status: 'unmanaged', observedHash: hash(operation.properties) });
      }
    }
  }
  return results.sort((a, b) => a.path.localeCompare(b.path));
}
export async function assertPrivacy(adapter, config, regions) {
  for (const region of regions) {
    const apim = await adapter.arm('GET', region.id, version);
    requireThat(apim.properties.publicNetworkAccess === 'Disabled', `Gateway public access is not disabled: ${region.name}.`);
    const connections = await adapter.arm('GET', `${region.id}/privateEndpointConnections`, version);
    const marker = `azd:${config.AZURE_ENV_NAME}:${region.key}:${config.FRONT_DOOR_PROFILE_NAME}`;
    const approved = connections.value.filter(connection => connection.properties.privateLinkServiceConnectionState.status === 'Approved');
    requireThat(!connections.nextLink && approved.length === 1 && approved[0].properties.privateLinkServiceConnectionState.description === marker,
      `Expected one correlated approved Private Link connection: ${region.name}.`);
    const originId = `/subscriptions/${config.AZURE_SUBSCRIPTION_ID}/resourceGroups/${config.AZURE_RESOURCE_GROUP}/providers/Microsoft.Cdn/profiles/${config.FRONT_DOOR_PROFILE_NAME}/originGroups/${config.FRONT_DOOR_ORIGIN_GROUP_NAME}/origins/${region.key}`;
    const origin = (await adapter.arm('GET', originId, '2025-04-15')).properties.sharedPrivateLinkResource;
    requireThat(origin.privateLink.id.toLowerCase() === region.id.toLowerCase() && origin.groupId === 'Gateway' && origin.requestMessage === marker,
      `Front Door origin does not match the expected private APIM connection: ${region.name}.`);
  }
}
export async function deletionResources(manifest, source, resources, readGit = git) {
  if (!manifest) return [];
  requireThat(manifest.schemaVersion === 1 && sha.test(manifest.baseRevision) &&
    Array.isArray(manifest.operations) && manifest.operations.length > 0, 'Invalid deletion manifest.');
  const seen = new Set();
  return manifest.operations.map(entry => {
    requireThat(entry && typeof entry.reason === 'string' && entry.reason.trim().length >= 10, 'Every deletion needs a reviewable reason.');
    const match = /^apis\/([a-zA-Z0-9][a-zA-Z0-9_.-]*)\/operations\/([a-zA-Z0-9][a-zA-Z0-9_.-]*)$/.exec(entry.path);
    requireThat(match && !seen.has(entry.path), 'Deletion allowlist supports unique explicit API operation paths only.');
    seen.add(entry.path);
    const [, api, operation] = match;
    requireThat(!(api === 'regional-demo' && ['region', 'ready'].includes(operation)), 'Required demo operations cannot be deleted.');
    requireThat(resources.some(resource => resource.path === `apis/${api}`) &&
      !resources.some(resource => resource.path === entry.path), 'A deleted operation must be absent from artifacts and its parent API must remain managed.');
    requireThat(!source.files.some(([path]) => path.startsWith(`apis/${api}/operations/${operation}/`)), 'Remove all operation artifacts before deletion.');
    readGit(['cat-file', '-e', `${manifest.baseRevision}:apim-artifacts/apis/${api}/operations/${operation}/operationInformation.json`]);
    return { path: entry.path, descriptor: { type: 'ApiOperation', nameParts: [api, operation] } };
  });
}
function planIdentity(report) {
  return {
    schemaVersion: 1, commit: report.commit, artifactHash: report.artifactHash,
    configurationHash: report.configurationHash, deletionHash: report.deletionHash,
    toolHash: report.toolHash,
  };
}
export function assertPlan(plan, report, comparisons, now = Date.now()) {
  requireThat(plan?.status === 'planned' && plan.schemaVersion === 1, 'Expected a successful preview plan.');
  requireThat(canonical(planIdentity(plan)) === canonical(planIdentity(report)), 'Plan does not match the commit, artifacts, configuration, deletion manifest, or toolchain. Preview again.');
  const age = now - Date.parse(plan.createdAt);
  requireThat(Number.isFinite(age) && age >= 0 && age <= 24 * 60 * 60 * 1000, 'Plan is expired or has an invalid timestamp. Preview again.');
  requireThat(hash(plan.regions.map(region => region.comparison)) === hash(comparisons), 'Live managed configuration changed after preview. Preview again.');
}
export async function applyDeletions(client, region, deletions) {
  for (const deletion of deletions) {
    await client.deleteResource(region.context, deletion.descriptor);
    requireThat(!await client.getResource(region.context, deletion.descriptor), `Deletion did not verify: ${deletion.path}.`);
  }
}
export function productionAdapter(wait = sleep) {
  const client = new LifecycleApimClient('https://management.azure.com/.default');
  return {
    client, sleep: wait,
    async arm(method, path, apiVersion, body) {
      const response = await client.request(`https://management.azure.com${path}?api-version=${apiVersion}`, {
        method, ...(body ? { body: JSON.stringify(body), headers: { 'Content-Type': 'application/json' } } : {}),
      });
      requireThat(response.ok, `ARM ${method} failed with HTTP ${response.status}.`);
      return response.json();
    },
    async backend(config, region) {
      const clusterId = `/subscriptions/${config.AZURE_SUBSCRIPTION_ID}/resourceGroups/${region.group}/providers/Microsoft.ContainerService/managedClusters/${region.cluster}`;
      const script = `import json,urllib.request; r=urllib.request.urlopen("http://${region.backend}/health/ready",timeout=15); assert r.status==200; b=json.load(r); assert b.get("status")=="ok" and b.get("region")=="${region.location}"`;
      const response = await client.request(`https://management.azure.com${clusterId}/runCommand?api-version=2025-01-01`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          command: `kubectl -n private-poc exec deployment/regional-demo -- python -c '${script}'`,
          clusterToken: (await client.credential.getToken('6dae42f8-4368-4678-94ff-3960e28e3630/.default')).token,
        }),
      });
      requireThat(response.status === 202, `AKS backend verification submission failed: HTTP ${response.status}.`);
      const location = new URL(response.headers.get('Location'));
      requireThat(location.origin === 'https://management.azure.com' &&
        location.pathname.toLowerCase().startsWith(`${clusterId}/commandResults/`.toLowerCase()), 'Unexpected AKS command result URL.');
      for (let attempt = 0; attempt < 60; attempt++) {
        await wait(5000);
        const resultResponse = await client.request(location.href, { method: 'GET' });
        if (resultResponse.status === 202) continue;
        requireThat(resultResponse.ok, `AKS verification result failed: HTTP ${resultResponse.status}.`);
        const result = await resultResponse.json();
        const properties = result.properties ?? result;
        if (['Running', 'Creating'].includes(properties.provisioningState)) continue;
        requireThat(properties.provisioningState === 'Succeeded' && properties.exitCode === 0,
          `Regional backend verification failed: ${region.name}. Inspect the AKS command result in Azure.`);
        return { status: 'passed' };
      }
      throw new Error(`Regional backend verification timed out: ${region.name}.`);
    },
    async http(url, headers = {}) {
      const response = await fetch(url, { headers, redirect: 'error', signal: AbortSignal.timeout(30000) });
      return { status: response.status, headers: Object.fromEntries(response.headers), body: await response.json() };
    },
    publish(region, source, config) {
      return runPublish(client, new ArtifactStore(), {
        service: region.context, sourceDir: source.directory, overrides: overridesFor(config, region),
        dryRun: false, deleteUnmatched: false, logLevel: 'error',
      });
    },
  };
}
export async function verifyRuntime(adapter, config, regions) {
  const result = { backends: [], publicGateways: [], observedFrontDoorRegions: [] };
  for (const region of regions) {
    await adapter.backend(config, region);
    result.backends.push({ target: region.name, status: 'passed' });
    const direct = await adapter.http(`https://${region.name}.azure-api.net/demo/`, { 'X-Azure-FDID': config.FRONT_DOOR_ID });
    requireThat([403, 404].includes(direct.status) && direct.body.statusCode === 403 &&
      /public network access.*disabled/i.test(direct.body.message) && direct.body.message.toLowerCase().includes(region.name.toLowerCase()), `Direct public APIM access was not confirmed blocked: ${region.name}.`);
    result.publicGateways.push({ target: region.name, status: 'blocked' });
  }
  for (let attempt = 0; attempt < 30; attempt++) {
    const observed = new Set();
    try {
      for (const url of [config.API_URL, config.API_HEALTH_URL]) {
        const response = await adapter.http(url);
        requireThat(response.status === 200 && regions.some(region => region.location === response.body.region) &&
          response.headers['x-served-region'] === response.body.region &&
          guid.test(response.headers['x-correlation-id'] ?? '') &&
          response.headers['cache-control']?.includes('no-store') &&
          (url === config.API_URL ? response.body.service === 'regional-demo' : response.body.status === 'ok'),
        'Invalid Front Door runtime contract.');
        observed.add(response.body.region);
      }
      result.observedFrontDoorRegions = [...observed].sort();
      break;
    } catch (error) {
      if (attempt === 29) throw error;
      console.error(`Front Door verification attempt ${attempt + 1} failed; waiting for propagation.`);
      await adapter.sleep(30000);
    }
  }
  result.gatewayCoverage = 'Front Door observations only; independent private gateway data paths are not proven.';
  return result;
}
export async function saveJson(path, value) {
  await mkdir(dirname(resolve(path)), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
}
export async function lifecycle(options, adapter = productionAdapter()) {
  const config = configFrom(options.config);
  if (options.action === 'export') {
    requireThat(options.output, 'Export requires --output.');
    await saveJson(options.output, config);
    return { status: 'exported', keys: configKeys.length };
  }
  const regions = regionsFrom(config);
  const createdAt = new Date().toISOString();
  const report = {
    schemaVersion: 1, action: options.action, createdAt, status: 'failed',
    configurationHash: hash(config), regions: regions.map(region => ({
      target: region.name, location: region.location, status: 'not-started', durationMs: 0,
    })),
  };
  let source;
  let stage = 'preflight';
  try {
    requireThat(['plan', 'publish', 'drift'].includes(options.action), 'Unsupported lifecycle action.');
    requireThat(!options.allowDelete || (options.action === 'publish' && options.plan && options.deletions),
      'Deletion requires publish, an explicit preview plan, a manifest, and --allow-delete.');
    requireThat(!options.deletions || options.action !== 'publish' || options.allowDelete,
      'Publishing a deletion manifest requires --allow-delete.');
    source = await sourceSnapshot(options.revision);
    report.commit = source.commit;
    report.artifactHash = source.artifactHash;
    report.toolHash = hash([
      (await readFile(join(root, 'scripts', 'apiops.mjs'), 'utf8')).replaceAll('\r\n', '\n'),
      (await readFile(join(root, 'package-lock.json'), 'utf8')).replaceAll('\r\n', '\n'),
    ]);
    const manifest = options.deletions ? JSON.parse(await readFile(options.deletions, 'utf8')) : null;
    report.deletionHash = hash(manifest);
    const expected = await Promise.all(regions.map(region => expectedResources(source, config, region)));
    const deletions = await deletionResources(manifest, source, expected[0], adapter.readGit);
    report.deletions = deletions.map(resource => resource.path);
    await assertPrivacy(adapter, config, regions);
    const comparisons = [];
    for (const [index, region] of regions.entries()) {
      const comparison = (await compareResources(adapter.client, region, expected[index]))
        .filter(resource => !deletions.some(deletion => deletion.path === resource.path));
      for (const deletion of deletions) {
        const actual = await adapter.client.getResource(region.context, deletion.descriptor);
        comparison.push({ path: deletion.path, status: actual ? 'delete' : 'absent', observedHash: hash(actual?.properties ?? null) });
      }
      comparisons.push(comparison);
      report.regions[index].comparison = comparison;
      report.regions[index].status = 'checked';
    }
    if (options.action === 'plan') {
      report.status = 'planned';
      requireThat(options.plan, 'Preview requires --plan output path.');
      await saveJson(options.plan, report);
    } else if (options.action === 'drift') {
      report.status = comparisons.flat().some(resource => !['matching', 'absent'].includes(resource.status)) ? 'drifted' : 'matching';
    } else {
      if (options.plan) assertPlan(JSON.parse(await readFile(options.plan, 'utf8')), report, comparisons);
      for (const [index, region] of regions.entries()) {
        stage = `publish:${region.key}`;
        const started = Date.now();
        const entry = report.regions[index];
        entry.status = 'publishing';
        try {
          const result = await adapter.publish(region, source, config);
          entry.publication = {
            exitCode: result.exitCode, errors: result.totalErrors,
            actions: result.actions.map(action => ({
              path: buildResourceLabel(action.descriptor), action: action.action, status: action.status,
            })),
          };
          requireThat(result.exitCode === 0 && result.totalErrors === 0, `APIOps publication failed: ${region.name}.`);
          stage = `delete:${region.key}`;
          await applyDeletions(adapter.client, region, deletions);
          stage = `verify:${region.key}`;
          entry.comparison = await compareResources(adapter.client, region, expected[index]);
          requireThat(entry.comparison.every(resource => ['matching', 'unmanaged'].includes(resource.status)), `Published configuration did not verify: ${region.name}.`);
          entry.status = 'verified-configuration';
        } catch (error) {
          entry.status = 'failed';
          throw error;
        } finally {
          entry.durationMs = Date.now() - started;
        }
      }
      stage = 'runtime-verification';
      report.runtime = await verifyRuntime(adapter, config, regions);
      report.status = 'verified';
    }
    return report;
  } catch (error) {
    report.status = 'failed';
    report.failedStage = stage;
    if (stage === 'runtime-verification') report.runtime = { status: 'failed' };
    // Raw SDK/ARM errors can contain resource bodies or credentials; only the stage is persisted.
    console.error(`APIOps ${options.action} failed at ${stage}: ${error instanceof LifecycleError ? error.message : 'SDK, Git or filesystem error; publication was not verified.'}`);
    throw error;
  } finally {
    report.completedAt = new Date().toISOString();
    if (source) await rm(source.directory, { recursive: true });
    if (options.report) await saveJson(options.report, report);
  }
}
async function main() {
  const { values } = parseArgs({ options: {
    action: { type: 'string', default: 'plan' }, config: { type: 'string' },
    output: { type: 'string' }, revision: { type: 'string' }, plan: { type: 'string' },
    report: { type: 'string', default: join(root, 'TestResults', `apiops-${Date.now()}.json`) },
    deletions: { type: 'string' }, 'allow-delete': { type: 'boolean', default: false },
  } });
  requireThat(values.config, '--config is required (path or - for stdin).');
  let raw;
  if (values.config === '-') {
    raw = '';
    for await (const chunk of process.stdin) raw += chunk.toString('utf8');
    raw = raw.replace(/^\uFEFF/, '');
  } else raw = await readFile(values.config, 'utf8');
  const result = await lifecycle({ ...values, config: JSON.parse(raw), allowDelete: values['allow-delete'] });
  console.log(result.status === 'exported' ? `APIOps configuration exported to ${values.output}.` : `APIOps ${result.status}. Report: ${values.report}`);
  if (result.status === 'drifted') process.exitCode = 3;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  logger.configure({ level: 'ERROR' });
  main().catch(error => {
    console.error(error instanceof LifecycleError ? error.message : 'APIOps lifecycle failed. Inspect the report and Azure operation results; raw resource bodies are not logged.');
    process.exitCode = 1;
  });
}
