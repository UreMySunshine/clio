'use strict';

async function load({ github, owner, repo, number }) {
  const comments = await github.paginate(github.rest.issues.listComments,
    { owner, repo, issue_number: number, per_page: 100 });
  for (const comment of comments) {
    delete comment.editor;
    if (comment.user?.id !== 199175422 || comment.performed_via_github_app?.id !== 1144995) continue;
    const { node } = await github.graphql(`query($id: ID!) {
      node(id: $id) { ... on IssueComment { id fullDatabaseId body updatedAt
        editor { __typename login ... on Bot { id } }
      } }
    }`, { id: comment.node_id });
    if (node?.id !== comment.node_id || String(node.fullDatabaseId) !== String(comment.id) ||
      node.body !== comment.body || Date.parse(node.updatedAt) !== Date.parse(comment.updated_at)) {
      throw new Error('Comment changed between REST and GraphQL reads');
    }
    comment.editor = node.editor;
  }
  return comments;
}

module.exports = { load };
