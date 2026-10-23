// Converts the current Typst documentation page to Markdown.
(() => {
  const root = document.querySelector('main') || document.body;
  const skip = (n) => ['script', 'style', 'button', 'svg', 'img', 'nav'].includes(n.tagName.toLowerCase())
    || n.classList.contains('copy') || n.classList.contains('tooltip-context') || n.classList.contains('preview');
  const inline = (node) => {
    let out = '';
    for (const n of node.childNodes) {
      if (n.nodeType === 3) { out += n.textContent; continue; }
      if (n.nodeType !== 1 || skip(n)) continue;
      const tag = n.tagName.toLowerCase();
      const inner = inline(n);
      if (tag === 'code') out += '`' + n.textContent + '`';
      else if (tag === 'strong' || tag === 'b') out += '**' + inner + '**';
      else if (tag === 'em' || tag === 'i') out += '*' + inner + '*';
      else if (tag === 'a') {
        const href = n.getAttribute('href') || '';
        const url = href.startsWith('/') ? 'https://typst.app/docs' + href : href;
        out += url ? '[' + inner + '](' + url + ')' : inner;
      } else out += inner;
    }
    return out;
  };
  const block = (node, depth) => {
    let out = '';
    for (const n of node.children) {
      if (skip(n)) continue;
      const tag = n.tagName.toLowerCase();
      if (/^h[1-6]$/.test(tag)) out += '#'.repeat(+tag[1]) + ' ' + inline(n).trim() + '\n\n';
      else if (tag === 'p') out += inline(n).trim() + '\n\n';
      else if (tag === 'pre') out += '```typ\n' + n.textContent.replace(/\n$/, '') + '\n```\n\n';
      else if (tag === 'ul' || tag === 'ol') {
        let i = 1;
        for (const li of n.children) {
          out += '  '.repeat(depth) + (tag === 'ol' ? (i++) + '. ' : '- ') + inline(li).trim().replace(/\n+/g, ' ') + '\n';
        }
        out += '\n';
      } else if (tag === 'table') {
        const rows = [...n.querySelectorAll('tr')].map(r => [...r.children].map(c => inline(c).trim().replace(/\|/g, '\\|')));
        if (rows.length) {
          out += '| ' + rows[0].join(' | ') + ' |\n|' + rows[0].map(() => ' --- |').join('') + '\n';
          for (const r of rows.slice(1)) out += '| ' + r.join(' | ') + ' |\n';
          out += '\n';
        }
      } else out += block(n, depth);
    }
    return out;
  };
  return block(root, 0).replace(/\n{3,}/g, '\n\n').trim() + '\n';
})()
