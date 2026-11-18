import collections, json, sys, unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import build_questions as bq  # noqa: E402
import judge_difficulty as jd  # noqa: E402


class DifficultyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import tempfile
        cls.tmp = tempfile.TemporaryDirectory()
        out = Path(cls.tmp.name) / "q.json"
        bq.main(str(out))
        cls.qs = json.loads(out.read_text(encoding="utf-8"))

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_every_question_has_difficulty_1_to_3(self):
        self.assertEqual(len(self.qs), 785)
        self.assertEqual({q["difficulty"] for q in self.qs}, {1, 2, 3})

    def test_saved_judgement_is_up_to_date(self):
        saved = json.loads((TOOLS / "data" / "difficulty.json").read_text(encoding="utf-8"))
        self.assertEqual(saved, {q["id"]: jd.judge(q) for q in self.qs}, "請重跑 judge_difficulty.py")

    def test_case_number_mapping(self):
        self.assertEqual(jd.case_no("L-L001"), 1)
        self.assertEqual(jd.case_no("L-L005"), 1)
        self.assertEqual(jd.case_no("L-L006"), 2)
        self.assertEqual(jd.case_no("L-L394"), 79)
        self.assertEqual(jd.case_no("L-M035"), 35)
        self.assertEqual(jd.case_no("L-D043"), 43)

    def test_rules_questions_are_basic_except_situational_tips(self):
        d = {q["id"]: q["difficulty"] for q in self.qs if q["source"] == "rules"}
        self.assertEqual(d["R-7-1"], 1)
        self.assertEqual(d["RL-2-2"], 1)
        self.assertEqual(d["RU-R01"], 1)
        self.assertEqual(d["TIP-X02"], 2)
        self.assertEqual(d["TIP-X03"], 3)

    def test_ask_matrix(self):
        self.assertEqual(jd.MATRIX["A"], (1, 1, 2))
        self.assertEqual(jd.MATRIX["G"], (2, 2, 3))

    def test_every_level_can_fill_an_exam(self):
        c = collections.Counter((q["difficulty"], q["qtype"] == "short") for q in self.qs)
        self.assertGreaterEqual(c[(1, False)], 20, "基礎考核（全選擇）要有 20 題以上")
        self.assertGreaterEqual(c[(2, False)] + c[(2, True)], 40)
        self.assertGreaterEqual(c[(3, False)] + c[(3, True)], 40)


if __name__ == "__main__":
    unittest.main()
