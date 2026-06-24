import { unified } from 'unified';
import uniorgParse from 'uniorg-parse';
import uniorg2rehype from 'uniorg-rehype';
import rehypeStringify from 'rehype-stringify';

// uniorg sees org files the way org-element.el does (drawers, src blocks,
// LaTeX, &c.), so we reuse it rather than writing our own parser. The pipeline
// is: org text -> org AST -> hast -> HTML string.
const processor = unified()
  .use(uniorgParse)
  .use(uniorg2rehype)
  .use(rehypeStringify);

export async function renderOrg(org: string): Promise<string> {
  return String(await processor.process(org));
}
