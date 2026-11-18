import assert from 'node:assert/strict';
import { login, EMP1 } from './_helpers.mjs';

export default async function ({ page, base, sql, shot }) {
  page.on('dialog', (d) => d.accept());
  await sql(`delete from exam_papers; delete from attempt_answers; delete from attempts; update questions set used = false, removed = false`);

  // ── 主管：產生草稿 → 刪 5 題 → 隨機補到 20 題 → 鎖定並出題 ──
  await login(page, base, 'boss@example.com');
  await page.click('#tab-papers');
  await page.waitForSelector('#create-paper');
  await page.selectOption('#p-user', EMP1);
  await page.selectOption('#p-stage', '12');
  await page.click('#create-paper');
  await page.waitForSelector('table.paper-questions tbody tr');
  assert.equal(await page.locator('table.paper-questions tbody tr').count(), 20, '草稿抽 20 題');
  assert.match(await page.textContent('#paper-meta'), /20／20/);
  assert.ok(await page.locator('#lock-paper').isEnabled(), '20 題時可以鎖定');
  assert.ok(await page.locator('#refill').isDisabled(), '已滿 20 題不用補');
  await shot('paper-draft');

  const removed = [];
  for (let i = 0; i < 5; i++) {
    const cb = page.locator('table.paper-questions input.pick').nth(i);
    removed.push(await cb.getAttribute('data-qid'));
    await cb.check();
  }
  await page.click('#remove-from-paper');
  await page.waitForFunction(() => document.querySelectorAll('table.paper-questions tbody tr').length === 15);
  assert.match(await page.textContent('#paper-meta'), /15／20/);
  assert.ok(await page.locator('#lock-paper').isDisabled(), '題數不足不能鎖定');
  const rows = await sql(`select count(*)::int c from questions where id in (${removed.map((x) => `'${x}'`).join(',')}) and removed`);
  assert.equal(rows[0].c, 5, '被刪的 5 題暫時移出');

  await page.click('#refill');
  await page.waitForFunction(() => document.querySelectorAll('table.paper-questions tbody tr').length === 20);
  const now = await page.locator('table.paper-questions tbody tr').evaluateAll((els) => els.map((e) => e.dataset.qid));
  assert.ok(!now.some((id) => removed.includes(id)), '補的題不是剛刪掉的');

  // 員工在鎖定前看不到開始考試
  await page.evaluate(() => localStorage.setItem('mock_user', 'e0000000-0000-0000-0000-000000000001'));
  await page.goto(base + '/home.html');
  await page.waitForSelector('.stage-card');
  assert.equal(await page.locator('a.btn[href^="exam.html"]').count(), 0, '鎖定前員工不能考');

  await page.evaluate(() => localStorage.setItem('mock_user', 'b0000000-0000-0000-0000-000000000001'));
  await page.goto(base + '/supervisor.html');
  await page.click('#tab-papers');
  await page.click('button.open-paper');
  await page.waitForSelector('#lock-paper');
  await page.click('#lock-paper');
  await page.waitForFunction(() => /已出題/.test(document.querySelector('#paper-meta')?.textContent ?? ''));
  assert.equal(await page.locator('#lock-paper').count(), 0, '鎖定後不能再改');
  assert.equal(await page.locator('table.paper-questions input.pick').count(), 0);
  await shot('paper-locked');

  // ── 員工：開始考試，考的就是鎖定的 20 題 ──
  await page.evaluate(() => localStorage.setItem('mock_user', 'e0000000-0000-0000-0000-000000000001'));
  await page.goto(base + '/home.html');
  await page.waitForSelector('.stage-card[data-stage="12"] a.btn');
  await page.click('.stage-card[data-stage="12"] a.btn');
  await page.waitForSelector('.qnav');
  assert.equal(await page.locator('.qnav').count(), 20);
  const [{ s }] = await sql(`select status s from exam_papers where user_id = '${EMP1}' and stage = 12`);
  assert.equal(s, 'used');
}
