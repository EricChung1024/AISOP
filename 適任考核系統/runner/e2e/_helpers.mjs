export async function login(page, base, email, pw = 'pass1234') {
  await page.goto(base + '/index.html');
  await page.fill('#email', email);
  await page.fill('#password', pw);
  await page.click('#go');
  await page.waitForURL(/(home|supervisor)\.html/);
}

/** 讀出最新一份考卷的題目（含畫面順序、perm、正確答案），給測試算出該點哪個選項。 */
export async function latestAttempt(sql, userId) {
  const [a] = await sql(`select id, question_ids from attempts where user_id = '${userId}' order by started_at desc limit 1`);
  const out = [];
  for (const { id, perm } of a.question_ids) {
    const [q] = await sql(`select id, qtype, correct_index from questions where id = '${id}'`);
    const shownRight = perm ? perm.indexOf(q.correct_index) : null;
    const shownWrong = perm ? perm.findIndex((o) => o !== q.correct_index) : null;
    out.push({ id, qtype: q.qtype, shownRight, shownWrong });
  }
  return { id: a.id, questions: out };
}

export const EMP1 = 'e0000000-0000-0000-0000-000000000001';
export const EMP2 = 'e0000000-0000-0000-0000-000000000002';

/** 模擬主管已鎖定考卷：為員工建立指定階段、依難度抽 20 題的已鎖定考卷。 */
export async function lockPaper(sql, userId, stage = 12) {
  const diff = { 12: 1, 13: 2, 14: 3 }[stage];
  const shorts = { 12: 0, 13: 2, 14: 3 }[stage];
  const mcq = await sql(`select id from questions where qtype <> 'short' and not removed order by abs(difficulty - ${diff}), random() limit ${20 - shorts}`);
  const sh = shorts ? await sql(`select id from questions where qtype = 'short' and not removed order by abs(difficulty - ${diff}), random() limit ${shorts}`) : [];
  const ids = [...mcq, ...sh].map((q) => `'${q.id}'`).join(',');
  await sql(`delete from exam_papers where user_id = '${userId}' and stage = ${stage}`);
  await sql(`insert into exam_papers (user_id, stage, question_ids, status, locked_at) values ('${userId}', ${stage}, array[${ids}]::text[], 'locked', now())`);
}
