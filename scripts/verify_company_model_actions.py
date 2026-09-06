#!/usr/bin/env python3
"""Run one explicitly selected demo colleague with the real configured model.

No fleet is started. The worker client rejects every other room route, and the
output is redacted public protocol evidence. Credentials remain in ignored files.
"""
import argparse
from dataclasses import replace
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from active_agent.config import Settings
from active_agent.im import IMAgent, IMClient, IMError
from active_agent.llm import OpenAICompatibleModel

OUTPUT = ROOT / "output/live-company-agent-actions.json"
STAMP = lambda: datetime.now(timezone.utc).isoformat()
SECRET_KEYS = {"token", "password", "api_key", "model_api_key", "authorization", "lease_token", "lease_hash", "finished_lease_hash"}


def main(stage):
    settings = Settings.from_env()
    if settings.model_name != "gpt-6-astra" or settings.model_reasoning_effort != "medium" or not settings.model_api_key:
        raise ValueError("Expected the user's configured gpt-6-astra medium model")
    demo = json.loads((ROOT / "data/office/demo-company.json").read_text())
    access = json.loads((ROOT / "data/office/access.json").read_text())
    admin_secret = json.loads((ROOT / "data/office/admin.json").read_text())["token"]
    base_url, room_id = demo["base_url"], demo["room_id"]
    if base_url != "http://127.0.0.1:3218":
        raise ValueError("This verifier operates only the named loopback demo")
    route = "/rooms/" + room_id
    agent = demo["agents"][stage]
    reader_person = demo["humans"]["engineering"]
    secrets = [settings.model_api_key, admin_secret, access["human"]["token"]]
    secrets += [h["account"]["password"] for h in demo["humans"].values()]

    def clean(value):
        if isinstance(value, dict):
            return {k: clean(v) for k, v in value.items() if k.lower() not in SECRET_KEYS}
        if isinstance(value, list):
            return [clean(v) for v in value]
        if isinstance(value, str):
            for secret in secrets:
                if secret:
                    value = value.replace(secret, "[REDACTED]")
        return value

    evidence = json.loads(OUTPUT.read_text()) if OUTPUT.exists() else {
        "schema": "live-company-native-actions/v1", "created_at": STAMP(),
        "room_id": room_id, "room_name": "人机共创公司 · 全员协作",
        "active_agent_baseline_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "doc_free_baseline_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT.parent/"doc_free", text=True).strip(),
        "model": {"requested": settings.model_name, "reasoning_effort": settings.model_reasoning_effort,
            "endpoint": settings.model_base_url, "api_style": settings.model_api_style,
            "key_sha256_prefix": hashlib.sha256(settings.model_api_key.encode()).hexdigest()[:12]},
        "scope": "One named synthetic demo room; no fleet, external messages or other room operations",
        "runs": [],
    }
    if evidence["room_id"] != room_id:
        raise ValueError("Evidence belongs to another room")
    if any(r.get("stage") == stage and r.get("passed") for r in evidence["runs"]):
        raise ValueError("Stage already passed; refusing to duplicate work")
    record = {"stage": stage, "started_at": STAMP(), "principal_id": agent["principal_id"],
        "principal_name": agent["name"], "reader_id": reader_person["principal_id"],
        "calls": [], "inferences": []}
    evidence["runs"].append(record)

    def save():
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        temporary = OUTPUT.with_suffix(".tmp")
        temporary.write_text(json.dumps(clean(evidence), ensure_ascii=False, indent=2)+"\n")
        temporary.chmod(0o600)
        temporary.replace(OUTPUT)

    class ScopedClient(IMClient):
        def request(self, method, path, body=None):
            if path not in {"/me", "/rooms"} and not path.startswith(route + "/"):
                raise ValueError("Attempted operation outside the demo room")
            entry = {"at": STAMP(), "method": method, "path": path}
            record["calls"].append(entry)
            try:
                result = super().request(method, path, body)
                if path == "/rooms":
                    result["rooms"] = [r for r in result["rooms"] if r["id"] == room_id]
                if result.get("turn"):
                    entry.update({"turn_id": result["turn"]["id"], "state": result["turn"]["status"]})
                if result.get("receipt"):
                    entry["receipt"] = result["receipt"]
                return result
            except IMError as exc:
                entry["error"] = {"status": exc.status, "code": exc.code}
                raise
            finally:
                save()

    class ObservedModel(OpenAICompatibleModel):
        def complete_json(self, system, user):
            observed = {"started_at": STAMP(), "context_sha256": hashlib.sha256(user.encode()).hexdigest()}
            record["inferences"].append(observed)
            started = time.monotonic()
            save()
            try:
                value = super().complete_json(system, user)
                observed["response_metadata"] = self.last_response_metadata
                observed["decision"] = value
                return value
            except Exception as exc:
                observed["error_class"] = type(exc).__name__
                observed["safe_error"] = str(exc)[:200]
                raise
            finally:
                observed["elapsed_seconds"] = round(time.monotonic()-started, 3)
                save()

    # All evidence/scope/repeat checks above run before any network request.
    # Every successful temporary login below is covered by the same cleanup.
    reader = None
    try:
        owner = IMClient(base_url, access["human"]["token"])
        workers = IMClient(base_url, admin_secret).request("GET", "/admin/workers")["workers"]
        credential = next(w["token"] for w in workers if w["principal"]["id"] == agent["principal_id"])
        secrets.append(credential)
        reader_session = IMClient(base_url, "public-login").request("POST", "/auth/login", reader_person["account"])
        reader = IMClient(base_url, reader_session["token"])
        secrets.append(reader_session["token"])
        if reader_session["principal"]["id"] != reader_person["principal_id"]:
            raise ValueError("The readback login did not authenticate the independent reader")
        record["reader_authenticated_principal"] = reader_session["principal"]
        current = owner.request("GET", route)
        if stage == "technical-writer":
            source = next(d for d in current["documents"] if d["title"] == "人机共创公司 · 可见协作约定")
            body = source["content"] + "\n\n## 技术写作同事当前交付\n\n" + (
                "技术写作同事请依据本文和已共享的验收清单，现在创建真正的共享文档《演示公司 · 新人协作入门》，"
                "写清独立登录、群内人机身份、查看共享文档与任务、计划和服务端回执的区别、未经验证不要写成通过。"
                "这是可由新人直接阅读的完整入门说明，不是消息中的草稿。然后创建一项可操作的阅读检查任务，"
                "交给演示·许清和，让她按文档检查入口与用语并记录待改项。不要替人声称已经检查，也不要把其他待验收任务标成完成。"
            )
            source = owner.request("PUT", route+"/documents/"+source["id"], {"base_revision":source["revision"],"content":body})["document"]
            record["stimulus"] = {"type":"document.updated", "document":source, "mentions":[]}
        else:
            if stage == "product":
                title = "形成演示公司的多端验收清单并交给运营执行"
                description = (
                    "请产品同事依据共享的《人机共创公司 · 可见协作约定》，现在创建一篇真正的共享文档《演示公司 · 多端验收清单》，"
                    "用清晰表格细化五位人类独立登录、同群可见、文档与任务版本一致、Agent计划和服务器回执可见这四项验收，"
                    "列出步骤、期待结果和待填写的实际结果；现有证据只证明演示账号已加入，不能宣称UI或功能已验收通过。"
                    "然后创建一项真实执行任务交给演示·周予安，要求她组织五位人类逐项验收并把证据写回共享文档。"
                    "当前需要完整共享文档与后续真实任务，不需要消息草稿，也不要凭空把验收或本任务标成done。"
                )
            else:
                title = "评审当前两份共享交付并形成工程复核任务"
                description = (
                    "请评审同事阅读当前共享的《演示公司 · 多端验收清单》和《演示公司 · 新人协作入门》，"
                    "现在创建真正的共享文档《演示公司 · 交付风险与复核记录》：区分文档已经存在的事实、仍待真人验证的条目和具体风险，"
                    "引用原文依据与版本，提出最多五个可执行检查点，不要虚构已经完成UI测试。"
                    "然后创建一个真实工程复核任务交给演示·陈星河，说明他应如何检查回执、文档版本和人机身份一致性并回填结论。"
                    "需要共享文档及后续任务，不是待保存草稿；没有真人验证证据的任务仍保持未完成。"
                )
            task = owner.request("POST", route+"/tasks", {"title":title,"description":description,"assignee_id":agent["principal_id"]})["task"]
            record["stimulus"] = {"type":"task.created", "task":task, "mentions":[]}
        save()
        print(json.dumps({"stage":stage,"state":"worker_started","principal":agent["name"],"stimulus":record["stimulus"]["type"]},ensure_ascii=False),flush=True)
        worker = IMAgent(replace(settings, doc_free_url=base_url, im_token=credential, im_admin_token="",doc_free_token=""),
            client=ScopedClient(base_url,credential), model=ObservedModel(settings.model_api_key,settings.model_base_url,
                settings.model_name,settings.model_timeout,settings.model_reasoning_effort,settings.model_api_style))
        record["cycle"] = worker.cycle()
        record["turns"] = []
        for item in record["cycle"]["results"]:
            tid = item["turn_id"]
            turn = owner.request("GET",route+"/turns/"+tid)["turn"]
            other_turn = reader.request("GET",route+"/turns/"+tid)["turn"]
            entry = {"turn":turn,"independent_reader_same_turn":turn==other_turn,"resources":[]}
            record["turns"].append(entry)
            room = reader.request("GET",route)
            for receipt in turn.get("action_receipts",[]):
                if receipt["status"] != "committed":
                    continue
                rid = receipt.get("resource_id")
                if receipt["operation"] in {"im_create_document","im_update_document"}:
                    a = owner.request("GET",route+"/documents/"+rid)["document"]
                    b = reader.request("GET",route+"/documents/"+rid)["document"]
                    entry["resources"].append({"type":"document","resource_id":rid,"independent_reader_same":a==b,"document":b})
                elif receipt["operation"] in {"im_create_task","im_update_task"}:
                    b = next(t for t in room["tasks"] if t["id"]==rid)
                    a = next(t for t in owner.request("GET",route)["tasks"] if t["id"]==rid)
                    entry["resources"].append({"type":"task","resource_id":rid,"independent_reader_same":a==b,"task":b})
        record["passed"] = len(record["inferences"])==1 and any(
            e["turn"]["status"]=="replied" and e["independent_reader_same_turn"] and
            len(e["turn"].get("action_receipts",[]))>=2 and
            all(r["status"]=="committed" and r["principal_id"]==agent["principal_id"] for r in e["turn"]["action_receipts"]) and
            {r["type"] for r in e["resources"]}>={"document","task"} and
            all(r["independent_reader_same"] for r in e["resources"]) for e in record["turns"])
        record["finished_at"] = STAMP()
        save()
        print(json.dumps({"stage":stage,"passed":record["passed"],"cycle":record["cycle"],
            "actions":[[{"operation":r["operation"],"status":r["status"],"resource_id":r.get("resource_id"),"after_revision":r.get("after_revision")} for r in e["turn"].get("action_receipts",[])] for e in record["turns"]],
            "model_calls":len(record["inferences"]),"evidence":str(OUTPUT)},ensure_ascii=False),flush=True)
        return 0 if record["passed"] else 1
    except Exception as exc:
        record["failed_at"] = STAMP()
        record["error"] = {"class":type(exc).__name__,**({"status":exc.status,"code":exc.code} if isinstance(exc,IMError) else {})}
        save()
        raise
    finally:
        if reader is not None:
            reader.request("POST","/auth/logout",{})


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage",choices=["product","technical-writer","reviewer"])
    try:
        sys.exit(main(parser.parse_args().stage))
    except Exception as exc:
        print(json.dumps({"error_class":type(exc).__name__,**({"status":exc.status,"code":exc.code} if isinstance(exc,IMError) else {})}),file=sys.stderr)
        sys.exit(2)
