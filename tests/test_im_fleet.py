from dataclasses import replace
import unittest

from active_agent.config import Settings
from active_agent.im_fleet import OfficeFleet


class FleetTests(unittest.TestCase):
    def test_host_limits_validate_and_unassigned_catalog_installations_do_not_start_workers(self):
        for values in [{"im_worker_slots": 0}, {"im_worker_slots": 33}, {"im_model_concurrency": 0}, {"im_model_concurrency": 9}, {"im_worker_slots": True}]:
            with self.assertRaises(ValueError): replace(Settings(), **values)
        configured = []
        class Registry:
            def request(self, method, route):
                return {"workers": [{"principal": {"id": "unused"}, "token": "fixture-unused", "runnable_room_count": 0}]}
        fleet = OfficeFleet(replace(Settings(), im_admin_token="fixture-admin", im_worker_slots=2, im_model_concurrency=1), Registry(), lambda s: configured.append(s))
        self.assertEqual(fleet.sync(), 0)
        self.assertEqual(configured, [])

    def test_five_colleagues_are_independent_and_rotation_replaces_only_affected_worker(self):
        configured = []
        class Registry:
            workers = [{"principal": {"id": "colleague-"+str(i)}, "token": "fixture-token-"+str(i)} for i in range(5)]
            def request(self, method, route): return {"workers": self.workers}
        class Agent:
            model = None
            def __init__(self, settings): configured.append(settings)
            def run(self, stop): stop.wait(5)
        registry = Registry()
        fleet = OfficeFleet(replace(Settings(), im_admin_token="fixture-admin", im_token="fixture-token-0"), registry, Agent)
        try:
            self.assertEqual(fleet.sync(), 5)
            self.assertEqual(len(set(s.im_token for s in configured)), 5)
            self.assertTrue(all(s.im_admin_token == "" and s.doc_free_token == "" for s in configured))
            old_thread, old_stop = fleet.workers["colleague-2"]
            registry.workers[2]["token"] = "fixture-token-2-rotated"
            self.assertEqual(fleet.sync(), 5)
            self.assertTrue(old_stop.is_set())
            self.assertIsNot(fleet.workers["colleague-2"][0], old_thread)
            self.assertEqual(len(configured), 6)
            registry.workers += [{"principal": {"id": "colleague-"+str(i)}, "token": "fixture-token-"+str(i)} for i in range(5, 100)]
            self.assertEqual(fleet.sync(), 8)
        finally:
            for thread, stop in fleet.workers.values(): stop.set(); thread.join(1)

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
