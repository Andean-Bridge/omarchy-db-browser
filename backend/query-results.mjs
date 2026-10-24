import { appendRow } from './drivers.mjs';

// Keep one display budget for the whole execution. Reaching a display limit
// discards further rows in that set; it must not cancel later SQL statements.
export class QueryResults {
  constructor(limit, cellBatch) {
    this.limit = limit;
    this.cellBatch = cellBatch;
    this.budget = { bytes: 0 };
    this.resultSets = [];
    this.omittedSets = 0;
    this.affectedRows = 0;
  }

  begin(columns) {
    if (this.resultSets.length >= 100) { this.omittedSets++; return null; }
    const result = { columns, rows: [], cellRefs: [], rowCount: 0, hasMore: false };
    this.resultSets.push(result);
    return result;
  }

  row(result, row) {
    if (!result) return;
    result.rowCount++;
    if (result.hasMore) return;
    if (result.rows.length >= this.limit || !appendRow(result.rows, row, this.budget, result.cellRefs, this.cellBatch)) result.hasMore = true;
  }

  finish(message = '') {
    const first = this.resultSets[0] || { columns: [], rows: [], cellRefs: [], rowCount: this.affectedRows, hasMore: false };
    const notes = [];
    if (message) notes.push(message);
    if (this.resultSets.length > 1) notes.push(`${this.resultSets.length} result sets returned.`);
    if (this.affectedRows) notes.push(`${this.affectedRows} rows affected.`);
    if (this.omittedSets) notes.push(`Display limit reached: ${this.omittedSets} additional result sets omitted (maximum 100). All statements were submitted.`);
    return { ...first, resultSets: this.resultSets, affectedRows: this.affectedRows, ...(notes.length ? { message: notes.join('\n') } : {}) };
  }
}
