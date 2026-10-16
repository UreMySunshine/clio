'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { load } = require('./load.cjs');

function fixture(overrides = {}) {
  const comment = { id: 6205851002, node_id: 'IC_example',
    user: { id: 199175422 }, performed_via_github_app: { id: 1144995 },
    body: 'summary', updated_at: '2026-10-16T01:23:01Z' };
  const node = { id: comment.node_id, fullDatabaseId: String(comment.id), body: comment.body,
    updatedAt: comment.updated_at,
    editor: { __typename: 'Bot', id: 'BOT_kgDOC98s_g', login: 'chatgpt-codex-connector' }, ...overrides };
  const github = { rest: { issues: { listComments() {} } },
    paginate: async () => [structuredClone(comment)], graphql: async () => ({ node }) };
  return { github, owner: 'UreMySunshine', repo: 'clio', number: 11 };
}
test('joins actual REST and GraphQL shapes without flattening Actor', async () => {
  const comments = await load(fixture());
  assert.deepEqual(comments[0].editor,
    { __typename: 'Bot', id: 'BOT_kgDOC98s_g', login: 'chatgpt-codex-connector' });
});
for (const change of [{ body: 'edited' }, { updatedAt: '2026-10-16T01:24:00Z' },
  { id: 'other-node' }, { fullDatabaseId: '1' }, { fullDatabaseId: undefined }]) {
  test(`inconsistent API snapshot ${JSON.stringify(change)} rejects`, async () => {
    await assert.rejects(load(fixture(change)), /changed between/);
  });
}
test('accepts a numeric fullDatabaseId when identical to REST ID', async () => {
  const comments = await load(fixture({ fullDatabaseId: 6205851002 }));
  assert.equal(comments[0].id, 6205851002);
});
test('API error propagates instead of supplying a passing result', async () => {
  const input = fixture(); input.github.graphql = async () => { throw Error('API unavailable'); };
  await assert.rejects(load(input), /API unavailable/);
});
