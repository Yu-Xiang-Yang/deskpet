/* Research window: conversation list, Markdown + KaTeX rendering, streaming display. */
(function () {
  "use strict";

  const native = (type, payload) => {
    try { window.webkit.messageHandlers.research.postMessage(Object.assign({ type }, payload || {})); }
    catch (_) { console.log("native", type, payload); }
  };
  window.addEventListener("error", (e) => native("log", { text: "JS error: " + e.message + " " + e.filename + ":" + e.lineno }));

  const $ = (id) => document.getElementById(id);
  const list = $("list"), messagesEl = $("messages"), input = $("input"), sendBtn = $("send");
  const titleEl = $("title"), metaEl = $("meta"), web = $("web"), search = $("search");

  let S = {
    daily: "日常对话", research: "科研对话", empty: "向科研助手提问：文献检索、公式推导、方法比较、论文写作……",
    emptyDaily: "这里保存与桌宠的日常对话记录。", send: "发送", stop: "停止", copy: "复制", copied: "已复制",
    sources: "参考来源", rename: "重命名", del: "删除", newTitle: "新的科研对话", web: "联网检索文献",
    placeholder: "输入科研问题，⌘↩ 发送", placeholderDaily: "和桌宠聊天，⌘↩ 发送", search: "搜索对话标题",
    renamePrompt: "新的标题", hintNoWeb: "",
  };

  let items = [];
  let selected = null;
  let conv = null;
  let busy = false;
  const streams = new Map(); // message id -> { raw, el, timer }

  const { renderMarkdown, highlight } = window.DeskPetMarkdown;

  // ------------------------------------------------------------ sidebar

  function fmtDate(ms) {
    const d = new Date(ms), now = new Date();
    const sameDay = d.toDateString() === now.toDateString();
    return sameDay ? d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
                   : d.toLocaleDateString([], { month: "short", day: "numeric" });
  }

  function renderList() {
    const q = search.value.trim().toLowerCase();
    list.innerHTML = "";
    let sepShown = false;
    items.filter((it) => !q || it.title.toLowerCase().includes(q)).forEach((it) => {
      if (it.kind === "research" && !sepShown) {
        const sep = document.createElement("li");
        sep.className = "sep";
        sep.textContent = S.research;
        list.appendChild(sep);
        sepShown = true;
      }
      const li = document.createElement("li");
      li.className = it.kind + (it.id === selected ? " active" : "");
      li.innerHTML = `<span class="t"></span><span class="d"></span>`;
      li.querySelector(".t").textContent = it.title;
      li.querySelector(".d").textContent = fmtDate(it.updated) + (it.count ? ` · ${it.count}` : "");
      li.onclick = () => native("select", { id: it.id });
      list.appendChild(li);
    });
  }

  // ------------------------------------------------------------ messages

  function messageEl(m) {
    const wrap = document.createElement("div");
    wrap.className = "msg " + m.role;
    wrap.dataset.id = m.id;
    const card = document.createElement("div");
    card.className = "card";
    if (m.role === "assistant") {
      card.innerHTML = `<div class="status"></div><div class="md"></div>`;
      const md = card.querySelector(".md");
      md.innerHTML = renderMarkdown(m.text || "");
      highlight(md);
      appendSources(card, m.citations);
    } else {
      card.textContent = m.text;
    }
    const time = document.createElement("div");
    time.className = "time";
    time.textContent = m.date ? new Date(m.date).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }) : "";
    if (m.role === "assistant") {
      const copy = document.createElement("button");
      copy.className = "copy";
      copy.textContent = S.copy;
      copy.onclick = () => {
        const raw = (streams.get(m.id) || {}).raw || m.text || "";
        native("copy", { text: raw });
        copy.textContent = S.copied;
        setTimeout(() => (copy.textContent = S.copy), 1200);
      };
      time.appendChild(copy);
    }
    card.appendChild(time);
    wrap.appendChild(card);
    return wrap;
  }

  function appendSources(card, citations) {
    card.querySelectorAll(".sources").forEach((e) => e.remove());
    if (!citations || !citations.length) return;
    const box = document.createElement("div");
    box.className = "sources";
    box.innerHTML = `<b></b><ol></ol>`;
    box.querySelector("b").textContent = S.sources;
    const ol = box.querySelector("ol");
    citations.forEach((c) => {
      const li = document.createElement("li");
      const a = document.createElement("a");
      a.href = c.url;
      a.textContent = c.title || c.url;
      li.appendChild(a);
      ol.appendChild(li);
    });
    const time = card.querySelector(".time");
    card.insertBefore(box, time);
  }

  function renderConversation() {
    messagesEl.innerHTML = "";
    if (!conv) return;
    titleEl.textContent = conv.title;
    const daily = conv.kind === "daily";
    $("rename").hidden = daily;
    $("delete").hidden = daily;
    web.parentElement.hidden = daily;
    input.placeholder = daily ? S.placeholderDaily : S.placeholder;
    if (!conv.messages.length) {
      const e = document.createElement("div");
      e.className = "empty";
      e.textContent = daily ? S.emptyDaily : S.empty;
      messagesEl.appendChild(e);
    }
    conv.messages.forEach((m) => messagesEl.appendChild(messageEl(m)));
    scrollDown(true);
  }

  function nearBottom() { return messagesEl.scrollHeight - messagesEl.scrollTop - messagesEl.clientHeight < 120; }
  function scrollDown(force) { if (force || nearBottom()) messagesEl.scrollTop = messagesEl.scrollHeight; }

  function findCard(id) {
    const el = messagesEl.querySelector(`.msg[data-id="${CSS.escape(id)}"] .card`);
    return el;
  }

  // ------------------------------------------------------------ composer

  function send() {
    const text = input.value.trim();
    if (busy) { native("stop"); return; }
    if (!text || !conv) return;
    input.value = "";
    native("send", { id: conv.id, text, web: web.checked });
  }
  sendBtn.onclick = send;
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); send(); }
  });
  $("new").onclick = () => native("new");
  $("rename").onclick = () => conv && native("rename", { id: conv.id, title: conv.title });
  titleEl.ondblclick = () => conv && conv.kind !== "daily" && native("rename", { id: conv.id, title: conv.title });
  $("delete").onclick = () => conv && native("delete", { id: conv.id, title: conv.title });
  search.oninput = renderList;
  web.onchange = () => native("web", { on: web.checked });

  // Links open in the default browser.
  document.addEventListener("click", (e) => {
    const a = e.target.closest("a[href]");
    if (!a) return;
    e.preventDefault();
    native("openURL", { url: a.href });
  });

  function setBusy(on) {
    busy = !!on;
    sendBtn.textContent = busy ? S.stop : S.send;
    sendBtn.classList.toggle("stop", busy);
  }

  // ------------------------------------------------------------ API for the native shell

  window.research = {
    init(opts) {
      opts = opts || {};
      S = Object.assign(S, opts.strings || {});
      web.checked = opts.web !== false;
      $("webLabel").textContent = S.web;
      search.placeholder = S.search;
      $("rename").textContent = S.rename;
      $("delete").textContent = S.del;
      $("hint").textContent = opts.hint || "";
      setBusy(false);
    },
    setList(newItems, selectedId) {
      items = newItems || [];
      if (selectedId) selected = selectedId;
      renderList();
    },
    show(c) {
      conv = c;
      selected = c.id;
      metaEl.textContent = c.meta || "";
      renderList();
      renderConversation();
      input.focus();
    },
    setMeta(text) { metaEl.textContent = text || ""; },
    setTitle(id, title) {
      if (conv && conv.id === id) { conv.title = title; titleEl.textContent = title; }
    },
    append(m) {
      if (!conv) return;
      const empty = messagesEl.querySelector(".empty");
      if (empty) empty.remove();
      conv.messages.push(m);
      messagesEl.appendChild(messageEl(m));
      scrollDown(true);
    },
    begin(id) {
      window.research.append({ id, role: "assistant", text: "", date: Date.now() });
      const card = findCard(id);
      card.querySelector(".md").classList.add("typing");
      streams.set(id, { raw: "", timer: null });
    },
    delta(id, text) {
      const s = streams.get(id);
      const card = findCard(id);
      if (!s || !card) return;
      s.raw += text;
      if (s.timer) return;
      s.timer = setTimeout(() => {
        s.timer = null;
        const md = card.querySelector(".md");
        md.innerHTML = renderMarkdown(s.raw);
        scrollDown(false);
      }, 120);
    },
    status(id, text) {
      const card = findCard(id);
      if (card) card.querySelector(".status").textContent = text || "";
      scrollDown(false);
    },
    finish(id, text, citations) {
      const s = streams.get(id) || {};
      clearTimeout(s.timer);
      streams.set(id, { raw: text });
      const card = findCard(id);
      if (!card) return;
      const md = card.querySelector(".md");
      md.classList.remove("typing");
      md.innerHTML = renderMarkdown(text || "");
      highlight(md);
      card.querySelector(".status").textContent = "";
      appendSources(card, citations);
      scrollDown(false);
    },
    fail(id, text) {
      const s = streams.get(id);
      if (s) clearTimeout(s.timer);
      const wrap = messagesEl.querySelector(`.msg[data-id="${CSS.escape(id)}"]`);
      if (wrap) wrap.remove();
      window.research.append({ id: id + "-err", role: "error", text, date: Date.now() });
    },
    setBusy,
    focus() { input.focus(); },
  };

  native("ready");

  // Standalone preview without the native shell.
  if (!window.webkit || !window.webkit.messageHandlers) {
    research.init({});
    research.setList([
      { id: "daily", title: S.daily, kind: "daily", updated: Date.now(), count: 12 },
      { id: "r1", title: "KAN 网络综述", kind: "research", updated: Date.now() - 3600e3, count: 4 },
    ], "r1");
    research.show({ id: "r1", title: "KAN 网络综述", kind: "research", meta: "claude-opus-5-5", messages: [
      { id: "u1", role: "user", text: "介绍 Kolmogorov–Arnold 表示定理", date: Date.now() - 60000 },
      { id: "a1", role: "assistant", date: Date.now(), citations: [{ title: "KAN: Kolmogorov-Arnold Networks", url: "https://arxiv.org/abs/2404.19756" }],
        text: "**定理**：任意多元连续函数 $f:[0,1]^n\\to\\mathbb{R}$ 可表示为\n\n$$f(x_1,\\dots,x_n)=\\sum_{q=0}^{2n}\\Phi_q\\Big(\\sum_{p=1}^{n}\\phi_{q,p}(x_p)\\Big)$$\n\n| 方法 | 参数 |\n|---|---|\n| MLP | 固定激活 |\n| KAN | 可学习样条 |\n\n```python\nimport torch\nx = torch.randn(3)  # $not math$\n```" },
    ] });
  }
})();
