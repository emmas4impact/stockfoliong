import unittest

from sqlalchemy import create_engine, text

from scripts.scrub_demo_database import PRIVATE_TABLES, scrub


class DemoDatabaseTests(unittest.TestCase):
    def setUp(self):
        self.engine = create_engine("sqlite://")
        self.addCleanup(self.engine.dispose)
        with self.engine.begin() as c:
            for name in (*PRIVATE_TABLES, "stocks"):
                c.execute(text(f"CREATE TABLE {name} (id INTEGER PRIMARY KEY)"))
                c.execute(text(f"INSERT INTO {name} VALUES (1)"))

    def test_preview_then_apply(self):
        self.assertEqual(set(scrub(self.engine).values()), {1})
        self.assertEqual(set(scrub(self.engine, apply=True).values()), {1})
        self.assertEqual(set(scrub(self.engine).values()), {0})
        with self.engine.connect() as c:
            self.assertEqual(c.scalar(text("SELECT count(*) FROM stocks")), 1)
