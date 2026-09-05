import tempfile
from pathlib import Path
import unittest

from active_agent.config import Settings
from active_agent.engine import ActiveAgent
from active_agent.mcp_server import respond
from active_agent.store import Store


class McpTest(unittest.TestCase):
    def test_initialize_and_list_tools(self):
        with tempfile.TemporaryDirectory() as tmp:
            agent = ActiveAgent(Store(Path(tmp) / "mcp.db"), Settings(db_path=Path(tmp) / "mcp.db"))
            initialized = respond({"jsonrpc": "2.0", "id": 1, "method": "initialize"}, agent)
            self.assertEqual(initialized["result"]["serverInfo"]["name"], "active-agent")
            listed = respond({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, agent)
            self.assertEqual(len(listed["result"]["tools"]), 5)


if __name__ == "__main__":
    unittest.main()
