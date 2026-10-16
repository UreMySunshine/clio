'use strict';

const BOT = 'chatgpt-codex-connector[bot]';
const BOT_ID = 199175422;
const APP_ID = 1144995;
const MARKER = '<!-- codex-pull-request-review-summary -->';

function evaluate({ head, comments }) {
  const deny = reason => ({ allowed: false, reason });
  if (!/^[a-f0-9]{40}$/.test(head)) return deny('invalid head');
  const summaries = comments.filter(comment =>
    comment.user?.id === BOT_ID && comment.user?.login === BOT &&
    comment.user?.type === 'Bot' &&
    comment.performed_via_github_app?.id === APP_ID &&
    comment.performed_via_github_app?.slug === 'chatgpt-codex-connector' &&
    comment.body?.startsWith(MARKER));
  if (summaries.length !== 1) return deny('missing or ambiguous summary');
  const summary = summaries[0];
  if (summary.editor?.__typename !== 'Bot' || summary.editor?.id !== 'BOT_kgDOC98s_g' ||
    summary.editor?.login !== 'chatgpt-codex-connector') return deny('untrusted editor');
  const matches = [...summary.body.matchAll(/<!-- codex-review-state:v1 ([^\n]+) -->/g)];
  if (matches.length !== 1) return deny('missing or ambiguous state');
  let state;
  try { state = JSON.parse(matches[0][1]); } catch { return deny('invalid JSON'); }
  if (!state || Object.keys(state).sort().join(',') !== 'code_review,security_review') {
    return deny('unknown schema');
  }
  const clear = review => review && review.commit_sha === head &&
    review.status === 'completed' && review.has_any_findings === false &&
    review.has_unresolved_findings === false;
  if (!clear(state.code_review)) return deny('code review incomplete, stale or has findings');
  const security = state.security_review;
  const inactive = security && security.commit_sha === null && security.status === null &&
    security.has_any_findings === null && security.has_unresolved_findings === null;
  if (!inactive && !clear(security)) return deny('security review incomplete, stale or has findings');
  return { allowed: true, reason: 'Codex completed with no findings for current head',
    commentId: summary.id, updatedAt: summary.updated_at };
}

module.exports = { evaluate };
