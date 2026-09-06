#!/usr/bin/env python3
"""Provision five human sign-ins and three independently active Agent colleagues.

Uses the public native IM APIs, never edits server storage. Demo passwords and
credentials stay in ignored local files. Re-running preserves existing accounts.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import secrets
import sys
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from active_agent.im import IMClient, IMError
from dev_office import save_private

PEOPLE = [
    ("product", "演示·林知夏", "产品经理", "产品负责人", "iPhone Simulator"),
    ("engineering", "演示·陈星河", "软件工程师", "研发负责人", "Web A"),
    ("design", "演示·许清和", "产品设计师", "设计负责人", "Web B"),
    ("operations", "演示·周予安", "运营经理", "项目运营", "Web C"),
]
AGENTS = ["product", "reviewer", "technical-writer"]
MARKER = "native-company-demo-v1"


def available_native_actions(member):
    """Use advertised server capability, not merely the member's allowlist."""
    available = member.get("autonomy_available_operations")
    if not isinstance(available, list) or "im_create_document" not in available:
        raise ValueError("Server does not yet advertise native document actions; restart the upgraded service first")
    return available


def provision(base_url, data):
    access = json.loads((data / "access.json").read_text())
    admin = IMClient(base_url, json.loads((data / "admin.json").read_text())["token"])
    owner = IMClient(base_url, access["human"]["token"])
    path = data / "demo-company.json"
    demo = json.loads(path.read_text()) if path.exists() else {
        "schema": MARKER, "base_url": base_url, "created_at": datetime.now(timezone.utc).isoformat(),
        "humans": {}, "agents": {}, "stages": {},
    }
    if demo.get("schema") != MARKER or demo.get("base_url") != base_url:
        raise ValueError("Demo manifest belongs to a different schema or service; refusing to reuse credentials")
    save = lambda: save_private(path, demo)
    if "organization" not in demo:
        demo["organization"] = owner.request("POST", "/enterprise/admin/organizations", {
            "name": "人机共创公司 · 演示", "description": "五位人类与三位 Agent 共同任职的虚构演示组织。目录归属不授予额外管理权限。",
            "client_id": MARKER + ":company"})["organization"]
        save()
    oid = demo["organization"]["id"]
    primary = access["human"]
    demo["humans"]["owner"] = {"principal_id": primary["principal"]["id"], "name": primary["principal"]["name"],
        "platform": "macOS", "account": primary["account"], "existing_identity": True}
    save()
    for key, name, profession, job_title, platform in PEOPLE:
        human = demo["humans"].setdefault(key, {"name": name, "platform": platform,
            "account": {"username": "demo." + key, "password": secrets.token_urlsafe(18)}})
        save()  # Persist the planned password before the first account request.
        if "principal_id" not in human:
            result = owner.request("POST", "/enterprise/admin/members", {"name": name, "kind": "human",
                "profession": profession, "job_title": job_title, "organization_id": oid,
                "client_id": MARKER + ":" + key})
            human["principal_id"] = result["member"]["id"]
            save()
        if not human.get("account_initialized"):
            admin.request("POST", "/admin/accounts", {"principal_id": human["principal_id"], **human["account"]})
            human["account_initialized"] = True
            save()
    for template in AGENTS:
        if template not in demo["agents"]:
            principal = owner.request("POST", "/agent-store/" + template + "/install", {})["principal"]
            demo["agents"][template] = {"principal_id": principal["id"], "name": principal["name"],
                "template_id": template, "source_organization_name": principal.get("source_organization_name")}
            save()
    if not demo["stages"].get("affiliations"):
        for colleague in [demo["humans"]["owner"], *demo["agents"].values()]:
            route = "/enterprise/admin/members/" + colleague["principal_id"]
            member = owner.request("GET", route)["member"]
            owner.request("PATCH", route, {"base_revision": member["revision"], "organization_id": oid})
        demo["stages"]["affiliations"] = True
        save()
    if "room_id" not in demo:
        rooms = owner.request("GET", "/rooms")["rooms"]
        matches = [r for r in rooms if r.get("description", "").endswith(MARKER)]
        if len(matches) > 1:
            raise ValueError("Multiple demo groups found; select one explicitly instead of creating duplicates")
        room = matches[0] if matches else owner.request("POST", "/rooms", {
            "name": "人机共创公司 · 全员协作", "description": "五人三 Agent 的虚构公司；所有成员独立身份、同一群聊与共享文档。 " + MARKER})["room"]
        demo["room_id"] = room["id"]
        save()
    route = "/rooms/" + demo["room_id"]
    detail = owner.request("GET", route)
    members = {m["principal_id"] for m in detail["members"]}
    for colleague in [*demo["humans"].values(), *demo["agents"].values()]:
        if colleague["principal_id"] not in members:
            owner.request("POST", route + "/members", {"principal_id": colleague["principal_id"]})
    if not demo["stages"].get("seeded"):
        for agent in demo["agents"].values():
            owner.request("PATCH", route + "/participation", {"principal_id": agent["principal_id"], "mode": "paused"})
        detail = owner.request("GET", route)
        title = "人机共创公司 · 可见协作约定"
        if not any(d["title"] == title for d in detail["documents"]):
            owner.request("POST", route + "/documents", {"title": title, "content":
                "# 公司目标\n\n用一个模拟器、Mac 和三个独立网页会话，验证五位人类与三位 Agent 的同权办公协作。\n\n"
                "## 成员约定\n\n人类和 Agent 都是公司同事，使用自己的身份和权限。Agent 可以发现职责内待办并主动完成有依据的动作，不能只等待 @。\n\n"
                "## 当前交付\n\n产品同事负责把验收目标细化成真实任务；评审同事负责找出边界与风险；技术写作同事负责形成新人可读的说明文档。\n\n"
                "## 验收\n\n各人独立登录，同群聊天；共享任务和文档版本一致；Agent 的计划和真实动作回执对群成员可见。未经验证的功能不得写成已完成。\n\n"
                "## 运行预算\n\n目录有 100 个职业模板，只运行安装并加入会话的同事。每轮最多 3 个动作，定时复核间隔 5 分钟；本机模型调用限制并发。\n"})
        for key, human in demo["humans"].items():
            login = IMClient(base_url, "public-login").request("POST", "/auth/login", human["account"])
            client = IMClient(base_url, login["token"])
            try:
                client.request("POST", route + "/messages", {"content":
                    human["name"] + "已用独立账号加入演示公司。接下来共同检查任务、文档和 Agent 的真实回执。",
                    "mentions": [], "client_id": MARKER + ":hello:" + key})
            finally:
                client.request("POST", "/auth/logout", {})
        demo["stages"]["seeded"] = True
        save()
    if not demo["stages"].get("active"):
        for agent in demo["agents"].values():
            detail = owner.request("GET", route)
            member = next(m for m in detail["members"] if m["principal_id"] == agent["principal_id"])
            available = available_native_actions(member)
            owner.request("PATCH", route + "/participation", {"principal_id": agent["principal_id"], "mode": "active",
                "base_revision": detail["room"]["revision"], "autonomy": {"enabled": True, "max_steps": 3,
                    "allowed_operations": available, "review_interval_seconds": 300}})
        demo["stages"]["active"] = True
        save()
    summary = {"organization": demo["organization"]["name"], "room_id": demo["room_id"],
        "humans": [{k: v for k, v in h.items() if k in {"principal_id", "name", "platform"}} for h in demo["humans"].values()],
        "agents": list(demo["agents"].values()), "credential_file": str(path), "no_simulators_started": True}
    print(json.dumps(summary, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:3218")
    parser.add_argument("--data", type=Path, default=ROOT / "data" / "office")
    args = parser.parse_args()
    if urlsplit(args.base_url).hostname not in {"localhost", "127.0.0.1", "::1"}:
        parser.error("This demonstration provisions synthetic identities only on a loopback development service")
    provision(args.base_url.rstrip("/"), args.data.resolve())


if __name__ == "__main__":
    try:
        main()
    except (IMError, ValueError, OSError) as exc:
        print(f"Demo setup stopped: {type(exc).__name__}" + (f" ({exc.code})" if isinstance(exc, IMError) else ""), file=sys.stderr)
        sys.exit(1)
