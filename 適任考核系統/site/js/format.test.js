import test from 'node:test';
import assert from 'node:assert/strict';
import { errorTypeCounts, stageLabel, statusOf, esc, errorMessage, fmtDate } from './format.js';

test('errorTypeCounts counts rows and sorts by count desc then name', () => {
  const rows = ['B', 'A', 'C', 'B', 'A', 'A'].map((error_type) => ({ error_type }));
  assert.deepEqual(errorTypeCounts(rows), [
    { error_type: 'A', cnt: 3 },
    { error_type: 'B', cnt: 2 },
    { error_type: 'C', cnt: 1 },
  ]);
});

test('errorTypeCounts sums pre-aggregated cnt fields', () => {
  const rows = [
    { error_type: 'X', cnt: 2 }, { error_type: 'Y', cnt: 5 }, { error_type: 'X', cnt: 4 },
  ];
  assert.deepEqual(errorTypeCounts(rows), [
    { error_type: 'X', cnt: 6 },
    { error_type: 'Y', cnt: 5 },
  ]);
});

test('errorTypeCounts ignores rows without an error type', () => {
  assert.deepEqual(errorTypeCounts([{ error_type: null }, {}]), []);
});

test('stageLabel names comprehensive exam and chapters', () => {
  assert.equal(stageLabel(0), '綜合適任考核');
  assert.match(stageLabel(7), /退換貨/);
  assert.throws(() => stageLabel(10));
  assert.throws(() => stageLabel(-1));
});

test('statusOf maps summary rows to labels', () => {
  assert.equal(statusOf(undefined), '未考');
  assert.equal(statusOf({ passed: true, attempts: 2 }), '已通過');
  assert.equal(statusOf({ passed: false, attempts: 1 }), '未通過');
});

test('esc escapes html special characters', () => {
  assert.equal(esc('<a href="x">&\'</a>'), '&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;');
});

test('errorMessage gives friendly text for known codes and falls back for unknown', () => {
  assert.match(errorMessage('NO_QUESTIONS'), /尚無題目/);
  assert.match(errorMessage('ATTEMPT_CLOSED'), /已交出|已結束/);
  assert.match(errorMessage('SOMETHING_ELSE'), /SOMETHING_ELSE/);
});

test('fmtDate formats valid dates and tolerates empty or invalid input', () => {
  assert.equal(fmtDate(null), '—');
  assert.equal(fmtDate('not a date'), '—');
  assert.match(fmtDate('2026-11-16T12:00:00Z'), /^2026-11-1[67] \d\d:\d\d$/);
});

test('NO_WRONG message says there is nothing to practice', () => {
  assert.match(errorMessage('NO_WRONG'), /沒有可重練/);
});
