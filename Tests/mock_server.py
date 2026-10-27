"""Mock of the Anthropic Messages and OpenAI Chat Completions streaming endpoints for the integration test, and of
the OpenAI-compatible speech endpoint (/audio/speech) for trying the cloud voice in a test run of the app.

Each request body is appended to requests.jsonl so that the test can inspect what the client sent (the Authorization
header redacted, since a test run of the app may send a real key).
Usage: python3 Tests/mock_server.py <port> <log-dir> [<speech delay in seconds>]
"""
import io
import json
import math
import sys
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
LOG = sys.argv[2] + "/requests.jsonl"
SPEECH_DELAY = float(sys.argv[3]) if len(sys.argv) > 3 else 0


def sse(handler, events):
    handler.send_response(200)
    handler.send_header("Content-Type", "text/event-stream")
    handler.end_headers()
    for name, data in events:
        chunk = (f"event: {name}\n" if name else "") + f"data: {data if isinstance(data, str) else json.dumps(data, ensure_ascii=False)}\n\n"
        raw = chunk.encode()
        # Split writes in the middle of multi-byte characters.
        for i in range(0, len(raw), 7):
            handler.wfile.write(raw[i:i + 7])
            handler.wfile.flush()


def inner_life(system, last):
    if not isinstance(last, str):
        last = json.dumps(last, ensure_ascii=False)
    """Structured replies of the pet's inner life, or None for an ordinary pet reply: a digest of the conversation
    (an episode with a follow-up and a fact when it mentions 组会) and inner thoughts (a due follow-up and a return are
    voiced, idle thoughts stay below the default threshold)."""
    if "【记忆整理】" in system:
        if "组会" not in last:
            return {"episodes": [], "facts": [], "updates": [], "insight": None}
        day = last[last.find("当前时间：") + 5:][:10]
        return {"episodes": [{"text": "主人说明天上午有组会，要汇报论文进展，有点紧张", "importance": 7,
                              "follow_up_at": day + " 23:59", "follow_up": "组会汇报顺利吗"}],
                "facts": [{"text": "主人每周三上午开组会", "importance": 6}],
                "updates": [], "insight": {"text": "主人最近为组会汇报有些焦虑", "importance": 5}}
    if "【观察屏幕】" in system:
        seen = '"type": "image"' in last or "image_url" in last
        return {"activity": "在 Xcode 里调试桌宠的 Swift 代码" if seen else "（没有收到截图）", "kind": "work", "private": False}
    if "【念头】" in system:
        if "到期要跟进的事" in last:
            return {"thoughts": [{"thought": "组会应该结束了", "say": "组会后来顺利吗？", "motion": "perk", "motivation": 5, "follow_up": "E1"}]}
        if "刚回到电脑前" in last:
            return {"thoughts": [{"thought": "主人回来了", "say": "回来啦～刚才去哪儿了？", "motion": "wave", "motivation": 4, "follow_up": None}]}
        return {"thoughts": [{"thought": "主人在专心工作", "say": "在忙什么呀？", "motion": "think", "motivation": 2, "follow_up": None},
                             {"thought": "有点想伸懒腰", "say": "", "motion": "stretch", "motivation": 3, "follow_up": None}]}
    return None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        """The Admin API's cost report in two pages (key "test-admin-key"): 123.45 + 50 cents, then 1000 cents."""
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "method": "GET"}, ensure_ascii=False) + "\n")
        if not self.path.startswith("/v1/organizations/cost_report"):
            self.send_response(404)
            self.end_headers()
            return
        if self.headers.get("x-api-key") != "test-admin-key":
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}')
            return
        if "page=p2" in self.path:
            body = {"data": [{"starting_at": "2026-10-28T00:00:00Z", "ending_at": "2026-10-29T00:00:00Z",
                              "results": [{"amount": "1000", "currency": "USD"}]}], "has_more": False, "next_page": None}
        else:
            body = {"data": [{"starting_at": "2026-10-26T00:00:00Z", "ending_at": "2026-10-27T00:00:00Z",
                              "results": [{"amount": "123.45", "currency": "USD"}, {"amount": "50", "currency": "USD"}]},
                             {"starting_at": "2026-10-27T00:00:00Z", "ending_at": "2026-10-28T00:00:00Z", "results": []}],
                    "has_more": True, "next_page": "p2"}
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(LOG, "a") as f:
            headers = {k: ("<redacted>" if k.lower() == "authorization" else v) for k, v in self.headers.items()}
            f.write(json.dumps({"path": self.path, "headers": headers, "body": body}, ensure_ascii=False) + "\n")
        if self.path.endswith("/v1/messages"):
            self.anthropic(body)
        elif self.path.endswith("/chat/completions"):
            self.openai(body)
        elif self.path.endswith("/audio/speech"):
            self.speech(body)
        else:
            self.send_response(404)
            self.end_headers()

    def anthropic(self, body):
        if self.headers.get("x-api-key") != "test-key":
            self.send_response(401)
            self.end_headers()
            self.wfile.write(b'{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}')
            return
        last = body["messages"][-1]
        has_tool_result = isinstance(last["content"], list) and any(b.get("type") == "tool_result" for b in last["content"])
        start = ("message_start", {"type": "message_start", "message": {"model": body["model"], "content": []}})
        if body.get("output_config", {}).get("format"):
            system = body.get("system") if isinstance(body.get("system"), str) else json.dumps(body.get("system"), ensure_ascii=False)
            inner = inner_life(system, json.dumps(last["content"], ensure_ascii=False))
            text = json.dumps(inner if inner is not None else {"reply": "你好呀～今天也要加油！", "motion": "happy", "remind": None}, ensure_ascii=False)
            events = [start,
                      ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
                      ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}}),
                      ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                      ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}}),
                      ("message_stop", {"type": "message_stop"})]
        elif not has_tool_result:
            events = [start,
                      ("ping", {"type": "ping"}),
                      ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": ""}}),
                      ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "sig-1"}}),
                      ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                      ("content_block_start", {"type": "content_block_start", "index": 1, "content_block": {"type": "text", "text": ""}}),
                      ("content_block_delta", {"type": "content_block_delta", "index": 1, "delta": {"type": "text_delta", "text": "我先检索文献。"}}),
                      ("content_block_stop", {"type": "content_block_stop", "index": 1}),
                      ("content_block_start", {"type": "content_block_start", "index": 2, "content_block": {"type": "tool_use", "id": "toolu_01", "name": "search_arxiv", "input": {}}}),
                      ("content_block_delta", {"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": "{\"query\": \"Kolmogorov"}}),
                      ("content_block_delta", {"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": "-Arnold networks\", \"max_results\": 2}"}}),
                      ("content_block_stop", {"type": "content_block_stop", "index": 2}),
                      ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use"}}),
                      ("message_stop", {"type": "message_stop"})]
        else:
            answer = "根据检索结果，KAN 将激活函数置于边上：$\\phi(x)=\\sum_i c_i B_i(x)$。"
            events = [start,
                      ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
                      ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": answer}}),
                      ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "citations_delta", "citation": {"type": "web_search_result_location", "url": "https://arxiv.org/abs/2404.19756", "title": "KAN"}}}),
                      ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                      ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}}),
                      ("message_stop", {"type": "message_stop"})]
        sse(self, events)

    def openai(self, body):
        model = body["model"]
        def chunk(delta, finish=None):
            return (None, {"model": model, "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]})
        if body["messages"][-1]["role"] == "tool":
            question = next((m["content"] for m in reversed(body["messages"]) if m["role"] == "user"), "")
            if "公式" in question:
                answer = ("**结论**：注意力机制按相似度对值向量加权求和，核心公式为\n\n"
                          "$$\\mathrm{Attention}(Q,K,V)=\\mathrm{softmax}\\left(\\frac{QK^\\top}{\\sqrt{d_k}}\\right)V$$\n\n"
                          "其中 $d_k$ 为键向量维度。要点：\n\n- 缩放因子 $1/\\sqrt{d_k}$ 防止点积过大导致梯度消失；\n"
                          "- 多头注意力并行计算 $h$ 组投影后拼接；\n- 计算复杂度为 $O(n^2 d)$。\n\n"
                          "参考文献：Vaswani et al., *Attention Is All You Need*, NeurIPS 2017.")
                if "详细" in question:
                    answer = answer + "\n\n" + "\n\n".join(f"**补充 {i}**：多头注意力将 $Q,K,V$ 投影到 $h$ 个子空间分别计算后拼接，" "再经线性变换输出。" for i in range(1, 7))
                pieces = [answer[i:i + 40] for i in range(0, len(answer), 40)]
                events = [chunk({"content": p}) for p in pieces] + [chunk({}, "stop"), (None, "[DONE]")]
            elif "【每日任务】" in question:
                result = body["messages"][-1]["content"]
                lines = [l.strip() for l in result.splitlines() if l.strip()][:9]
                answer = "**今日要点（模拟服务据工具结果整理）**\n\n" + "\n".join("- " + l for l in lines)
                events = [chunk({"content": answer[i:i + 60]}) for i in range(0, len(answer), 60)] + [chunk({}, "stop"), (None, "[DONE]")]
            else:
                events = [chunk({"content": "检索完成，"}), chunk({"content": "结论如下。"}), chunk({}, "stop"), (None, "[DONE]")]
        elif body.get("tools") and "tool_choice" not in body:
            question = body["messages"][-1].get("content") or ""
            if "新闻" in question:
                name, args = "search_news", {"query": "人工智能", "max_results": 3}
            elif "行情" in question:
                name, args = "get_stock_quotes", {"symbols": ["^IXIC", "NVDA", "AAPL"]}
            else:
                name, args = "search_semantic_scholar", {"query": "graph neural networks", "limit": 2}
            raw = json.dumps(args, ensure_ascii=False)
            events = [chunk({"role": "assistant", "content": ""}),
                      chunk({"tool_calls": [{"index": 0, "id": "call_1", "type": "function", "function": {"name": name, "arguments": raw[:8]}}]}),
                      chunk({"tool_calls": [{"index": 0, "function": {"arguments": raw[8:]}}]}),
                      chunk({}, "tool_calls"), (None, "[DONE]")]
        elif (inner := inner_life(next((m["content"] for m in body["messages"] if m["role"] == "system"), ""),
                                  body["messages"][-1].get("content") or "")) is not None:
            events = [chunk({"content": json.dumps(inner, ensure_ascii=False)}), chunk({}, "stop"), (None, "[DONE]")]
        else:
            asked = "提醒" in json.dumps(body["messages"][-1], ensure_ascii=False)
            remind = {"minutes": 30, "text": "开会"} if asked else None
            n = sum(1 for m in body["messages"] if m["role"] == "user")
            reply = "收到！" if asked else f"这是第 {n} 句回复喵～"
            events = [chunk({"content": json.dumps({"reply": reply, "motion": "nod", "remind": remind}, ensure_ascii=False)}),
                      chunk({}, "stop"), (None, "[DONE]")]
        sse(self, events)


    def speech(self, body):
        """A tone as WAV audio, 0.2 s per character of the text (0.6–8 s), after the optional delay; any key or none is
        accepted (as by a local service) except "wrong-key", which gets an OpenAI-style error."""
        time.sleep(SPEECH_DELAY)
        if self.headers.get("Authorization") == "Bearer wrong-key":
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"Invalid API key"}}')
            return
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            frames = int(16000 * min(8, max(0.6, 0.2 * len(body.get("input", "")))))
            w.writeframes(b"".join(int(8000 * math.sin(2 * math.pi * 440 * i / 16000)).to_bytes(2, "little", signed=True)
                                   for i in range(frames)))
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.end_headers()
        self.wfile.write(buf.getvalue())


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
