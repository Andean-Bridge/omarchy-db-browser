// GO is a SQL Server client separator, never a server statement. Track quoted
// text and nested comments so a line containing GO inside either stays intact.
export function sqlServerBatches(sql) {
  const batches = [];
  let quote = '', depth = 0, text = '', startLine = 1;
  const lines = sql.split('\n');
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    const line = lines[lineIndex];
    const separator = !quote && !depth && line.match(/^\s*GO(?:\s+(\d+))?\s*(?:--.*)?$/i);
    if (separator) {
      if (separator[1] && Number(separator[1]) !== 1) throw new Error('GO repeat counts are not supported. Run each batch explicitly.');
      if (text.trim()) batches.push({ sql: text, line: startLine });
      text = ''; startLine = lineIndex + 2;
      continue;
    }
    text += line + (lineIndex < lines.length - 1 ? '\n' : '');
    for (let i = 0; i < line.length; i++) {
      const c = line[i], next = line[i + 1];
      if (quote) {
        if (c === quote) { if (next === quote) i++; else quote = ''; }
      } else if (depth) {
        if (c === '/' && next === '*') { depth++; i++; }
        else if (c === '*' && next === '/') { depth--; i++; }
      } else if (c === '-' && next === '-') break;
      else if (c === '/' && next === '*') { depth++; i++; }
      else if (c === "'" || c === '"' || c === '[') quote = c === '[' ? ']' : c;
    }
  }
  if (text.trim()) batches.push({ sql: text, line: startLine });
  return batches;
}
