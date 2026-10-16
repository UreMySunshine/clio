'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { evaluate } = require('./evaluate.cjs');
const head = 'a'.repeat(40);
const clear = { commit_sha: head, status: 'completed', has_any_findings: false,
  has_unresolved_findings: false };
const inactive = { commit_sha: null, status: null, has_any_findings: null,
  has_unresolved_findings: null };
function fixture(review = clear, security = inactive) {
  return { head, comments: [{ id: 1, updated_at: '2026-10-16T00:00:00Z',
    user: { id: 199175422, login: 'chatgpt-codex-connector[bot]', type: 'Bot' },
    performed_via_github_app: { id: 1144995, slug: 'chatgpt-codex-connector' },
    editor: { __typename: 'Bot', id: 'BOT_kgDOC98s_g', login: 'chatgpt-codex-connector' },
    body: '<!-- codex-pull-request-review-summary -->\n<!-- codex-review-state:v1 ' +
      JSON.stringify({ code_review: review, security_review: security }) + ' -->' }] };
}
test('synthetic current-head completed clear result passes', () => {
  assert.equal(evaluate(fixture()).allowed, true);
});
for (const status of [null, 'queued', 'in_progress', 'failed', 'rate_limited', 'unknown']) {
  test(`status ${status} blocks`, () => {
    assert.equal(evaluate(fixture({ ...clear, status })).allowed, false);
  });
}
for (const change of [{ commit_sha: 'b'.repeat(40) }, { has_any_findings: true },
  { has_unresolved_findings: true }, { has_any_findings: null },
  { has_unresolved_findings: undefined }, { has_any_findings: 'false' }]) {
  test(`review ${JSON.stringify(change)} blocks`, () => {
    assert.equal(evaluate(fixture({ ...clear, ...change })).allowed, false);
  });
}
test('new head invalidates previous completion', () => {
  const input = fixture(); input.head = 'b'.repeat(40);
  assert.equal(evaluate(input).allowed, false);
});
test('no comment and legacy thumbs up block', () => {
  assert.equal(evaluate({ head, comments: [] }).allowed, false);
  const input = fixture(); input.comments[0].body = '👍';
  assert.equal(evaluate(input).allowed, false);
});
for (const field of ['id', 'login', 'type']) {
  test(`forged bot ${field} blocks`, () => {
    const input = fixture(); input.comments[0].user[field] = 'forged';
    assert.equal(evaluate(input).allowed, false);
  });
}
test('wrong App and human editor block', () => {
  const input = fixture(); input.comments[0].performed_via_github_app.id = 1;
  assert.equal(evaluate(input).allowed, false);
  input.comments[0].performed_via_github_app.id = 1144995;
  input.comments[0].editor = { login: 'UreMySunshine' };
  assert.equal(evaluate(input).allowed, false);
});
test('same editor login cannot replace immutable Bot identity', () => {
  const input = fixture(); input.comments[0].editor.__typename = 'User';
  assert.equal(evaluate(input).allowed, false);
  input.comments[0].editor.__typename = 'Bot'; input.comments[0].editor.id = 'another-bot';
  assert.equal(evaluate(input).allowed, false);
});
test('duplicate summaries and malformed JSON block', () => {
  const input = fixture(); input.comments.push(input.comments[0]);
  assert.equal(evaluate(input).allowed, false);
  input.comments.pop(); input.comments[0].body = input.comments[0].body.replace('"code_review"', 'invalid');
  assert.equal(evaluate(input).allowed, false);
});
test('active security review must also complete clear on current head', () => {
  assert.equal(evaluate(fixture(clear, { ...clear, status: 'in_progress' })).allowed, false);
  assert.equal(evaluate(fixture(clear, clear)).allowed, true);
});
