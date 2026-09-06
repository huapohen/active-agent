from dataclasses import replace
import unittest

from active_agent.config import Settings
from active_agent.im_fleet import OfficeFleet


class FleetTests(unittest.TestCase):
    def test_store_colleagues_get_individual_tokens_without_admin_credentials(self):
        configured=[]

        class Registry:
            workers=[{"principal":{"id":"installed-agent"},"token":"scoped-test-token"}]
            def request(self,method,route):
                self.last=(method,route)
                return {"workers":self.workers}

        class Agent:
            model=None
            def __init__(self,settings):
                configured.append(settings)
            def run(self,stop):
                stop.wait(5)

        registry=Registry()
        fleet=OfficeFleet(replace(Settings(),im_admin_token="test-admin",doc_free_token="legacy-test-admin"),registry,Agent)
        try:
            self.assertEqual(fleet.sync(),1)
            self.assertEqual(configured[0].im_token,"scoped-test-token")
            self.assertEqual(configured[0].im_admin_token,"")
            self.assertEqual(configured[0].doc_free_token,"")
            self.assertEqual(fleet.sync(),1)
            self.assertEqual(len(configured),1)
            thread,stop=fleet.workers["installed-agent"]
            registry.workers=[]
            self.assertEqual(fleet.sync(),0)
            self.assertTrue(stop.is_set())
            thread.join(1)
        finally:
            for _,stop in fleet.workers.values():stop.set()


if __name__=="__main__":unittest.main()
