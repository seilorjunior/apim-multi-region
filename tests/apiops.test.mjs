import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { ArtifactStore } from '../node_modules/@azure-tools/apiops-cli/dist/clients/artifact-store.js';
import { loadOverrideConfig } from '../node_modules/@azure-tools/apiops-cli/dist/lib/config-loader.js';
import { runPublish } from '../node_modules/@azure-tools/apiops-cli/dist/services/publish-service.js';

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
