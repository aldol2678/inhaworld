export function splitStatements(raw) {
  const out = [];
  let buf = '';
  let i = 0;
  let dollar = null; // e.g. '$$' or '$body$'
  let sq = false; // single-quoted string
  let dq = false; // double-quoted identifier
  let lineComment = false;
  let blockComment = false;
  while (i < raw.length) {
    const ch = raw[i];
    const next = raw[i + 1] ?? '';
    if (lineComment) {
      buf += ch;
      if (ch === '\n') lineComment = false;
      i++;
      continue;
    }
    if (blockComment) {
      buf += ch;
      if (ch === '*' && next === '/') { buf += next; i += 2; blockComment = false; continue; }
      i++;
      continue;
    }
    if (dollar) {
      buf += ch;
      if (raw.startsWith(dollar, i)) { buf += dollar.slice(1); i += dollar.length; dollar = null; continue; }
      i++;
      continue;
    }
    if (sq) {
      buf += ch;
      if (ch === "'") {
        if (next === "'") { buf += next; i += 2; continue; }
        sq = false;
      }
      i++;
      continue;
    }
    if (dq) {
      buf += ch;
      if (ch === '"') dq = false;
      i++;
      continue;
    }
    // not inside anything
    if (ch === '-' && next === '-') { lineComment = true; buf += ch; i++; continue; }
    if (ch === '/' && next === '*') { blockComment = true; buf += ch; i++; continue; }
    if (ch === "'") { sq = true; buf += ch; i++; continue; }
    if (ch === '"') { dq = true; buf += ch; i++; continue; }
    if (ch === '$') {
      const m = /^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/.exec(raw.slice(i));
      if (m) { dollar = m[0]; buf += dollar; i += dollar.length; continue; }
    }
    if (ch === ';') {
      const s = buf.trim();
      if (s) out.push(s);
      buf = '';
      i++;
      continue;
    }
    buf += ch;
    i++;
  }
  const tail = buf.trim();
  if (tail) out.push(tail);
  return out;
}
