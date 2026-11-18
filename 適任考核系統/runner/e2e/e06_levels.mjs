import assert from 'node:assert/strict';
import { login, latestAttempt, EMP1 } from './_helpers.mjs';

export default async function ({ page, base, sql, shot }) {
  page.on('dialog', (d) => d.accept());
  await sql(`delete from attempt_answers; delete from attempts; delete from wrong_book;
             update profiles set hire_date = current_date - 200 where id = '${EMP1}'`);

  // ── 員工首頁：三階段考核與期限（到職約 200 天前＝滿 6 個月，等級 Lv.3） ──
  await login(page, base, 'emp1@example.com');
  await page.waitForSelector('#formal .stage-card');
  assert.equal(await page.locator('#formal .stage-card').count(), 3, '三階段：基礎／情境應用／綜合');
  assert.match(await page.textContent('#level'), /Lv\.3 客服專員/);
  const first = page.locator('#formal .stage-card[data-stage="12"]');
  const third = page.locator('#formal .stage-card[data-stage="14"]');
  assert.match(await first.textContent(), /基礎考核/);
  assert.match(await first.textContent(), /80 分/);
  assert.match(await page.locator('#formal .stage-card[data-stage="13"]').textContent(), /85 分/);
  assert.match(await third.textContent(), /90 分/, '綜合考核通過分 90 要寫出來');
  assert.ok(await first.locator('.due.overdue').count() === 1, '已超過期限且未通過');
  await shot('home-formal');

  // ── 考試：基礎考核（20 題，全對） ──
  await first.locator('a.btn').click();
  await page.waitForSelector('.qnav');
  const att = await latestAttempt(sql, EMP1);
  assert.equal(att.questions.length, 20, '基礎考核 20 題');
  for (let i = 0; i < att.questions.length; i++) {
    await page.click(`.qnav[data-i="${i}"]`);
    const q = att.questions[i];
    if (q.qtype === 'short') await page.fill(`textarea[data-qid="${q.id}"]`, '我的回覆');
    else await page.check(`input[data-qid="${q.id}"][value="${q.shownRight}"]`);
  }
  await page.click('#submit');
  await page.waitForSelector('.selfcheck, .score');
  if (await page.locator('.selfcheck').count()) {
    for (const cb of await page.locator('.selfcheck input[type=checkbox]').all()) await cb.check();
    await page.click('#submit-selfcheck');
    await page.waitForSelector('.score');
  }
  assert.match(await page.textContent('.score'), /100/);
  assert.match(await page.textContent('main'), /80 分及格/, '結果頁依該階段顯示通過分');

  // ── 回首頁：基礎考核已通過 ──
  await page.goto(base + '/home.html');
  await page.waitForSelector('#formal .stage-card');
  assert.match(await page.locator('#formal .stage-card[data-stage="12"] .due').textContent(), /已通過/);

  // ── 主管：矩陣只有三階段與考核期限；可設定到職日 ──
  await page.evaluate(() => localStorage.setItem('mock_user', 'b0000000-0000-0000-0000-000000000001'));
  await page.goto(base + '/supervisor.html');
  await page.waitForSelector('table.matrix tbody tr');
  const heads = await page.locator('table.matrix thead th').allTextContents();
  assert.ok(heads.includes('基礎') && heads.includes('情境') && heads.includes('考核期限'), '欄位：' + heads.join(','));
  assert.match(await page.locator('table.matrix tr:has-text("員工甲") td[data-stage="12"]').textContent(), /100/);
  assert.match(await page.locator('table.matrix tr:has-text("員工甲") td.due-col').textContent(), /Lv\.3/);
  await shot('supervisor-levels');

  await page.click('a.emp-link:has-text("員工甲")');
  await page.waitForSelector('#hire-date');
  await page.fill('#hire-date', '2026-01-31');
  await page.click('#save-hire');
  await page.waitForSelector('.notice.ok');
  assert.equal((await sql(`select hire_date::text as h from profiles where id = '${EMP1}'`))[0].h, '2026-01-31');
  const fs = await page.textContent('.formal-status');
  assert.match(fs, /2026-04-30/, '滿 3 個月：1/31 → 4/30（週四）：' + fs);
  assert.match(fs, /2026-07-31/, '滿 6 個月：7/31（週五）：' + fs);
}
