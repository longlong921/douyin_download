import React, { useState } from "react";
import { createRoot } from "react-dom/client";
import "./style.css";
type Video = {
  id: string;
  title: string;
  author: string | null;
  duration: number | null;
  cover: string | null;
  preview_url: string;
  download_url: string;
};
function App() {
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<Video | null>(null);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  async function parse() {
    if (!text.trim()) {
      setError("请先粘贴抖音分享内容。");
      return;
    }
    setBusy(true);
    setError("");
    setResult(null);
    setNotice("");
    try {
      const r = await fetch("/api/parse", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text }),
        signal: AbortSignal.timeout(65000),
      });
      const d = await r.json();
      if (!r.ok)
        throw Error(d.error?.message || "解析请求失败，请检查输入后重试。");
      setResult(d);
    } catch (e) {
      setError(
        e instanceof Error
          ? e.name === "TimeoutError"
            ? "解析超时，请稍后重试。"
            : e.message === "Failed to fetch"
              ? "无法连接服务器，请检查网络后重试。"
              : e.message
          : "解析失败，请重试。",
      );
    } finally {
      setBusy(false);
    }
  }
  async function paste() {
    try {
      setText(await navigator.clipboard.readText());
      setError("");
    } catch {
      setNotice("请长按输入框，选择“粘贴”。");
      document.querySelector("textarea")?.focus();
    }
  }
  return (
    <main>
      <header>
        <a className="brand" href="/" aria-label="拾影首页">
          <span className="logo">↓</span>拾影
          <span className="brand-small">视频下载</span>
        </a>
        <span className="badge">本地保存</span>
      </header>
      <section className="intro">
        <p className="eyebrow">KEEP THE MOMENT</p>
        <h1>
          喜欢的视频，
          <br />
          <span>留在手机里。</span>
        </h1>
        <p>
          复制抖音分享内容，粘贴到这里。
          <br className="mobile" />
          预览确认后，一键保存。
        </p>
      </section>
      <div className="workspace">
        <section className="input-card" aria-label="解析视频">
          <div className="card-top">
            <h2>
              <span className="step">01</span>粘贴分享内容
            </h2>
            <button
              className="text-button"
              disabled={busy || !text}
              onClick={() => {
                setText("");
                setResult(null);
                setError("");
                setNotice("");
              }}
            >
              清空
            </button>
          </div>
          <label className="sr-only" htmlFor="share">
            抖音分享链接或文案
          </label>
          <textarea
            id="share"
            maxLength={8192}
            disabled={busy}
            value={text}
            onChange={(e) => setText(e.target.value)}
            placeholder={"在这里粘贴分享链接或整段文案\nhttps://v.douyin.com/…"}
          />
          <div className="input-meta">
            <span>支持短链接 · 视频链接 · 分享文案</span>
            <button className="text-button" onClick={paste} disabled={busy}>
              粘贴
            </button>
          </div>
          <button className="primary" disabled={busy} onClick={parse}>
            {busy ? (
              <>
                <span className="spinner" />
                正在解析，请稍候…
              </>
            ) : (
              <>
                解析视频 <span>→</span>
              </>
            )}
          </button>
          {error && (
            <div className="error" role="alert">
              <strong>暂时无法解析</strong>
              <p>{error}</p>
              <button className="retry" onClick={parse} disabled={busy}>
                重新尝试 ↻
              </button>
            </div>
          )}
          <p className="notice" role="status">
            {notice ||
              (busy
                ? "正在连接抖音并读取作品信息，通常需要几秒钟。"
                : "视频由平台提供，部分作品可能需要登录或验证。")}
          </p>
        </section>
        <section
          className={"result-card " + (result ? "ready" : "")}
          aria-label="视频预览"
          aria-live="polite"
        >
          <h2>
            <span className="step">02</span>
            {result ? "预览并保存" : "等待你的下一段精彩"}
          </h2>
          {result ? (
            <>
              <video
                key={result.preview_url}
                controls
                playsInline
                preload="metadata"
                poster={result.cover || undefined}
                src={result.preview_url}
                onError={() =>
                  setNotice(
                    "预览加载失败，地址可能已过期。请重新解析；也可尝试直接下载。",
                  )
                }
              />
              <h3>{result.title}</h3>
              <p className="video-meta">
                {result.author || "作者信息未提供"} ·{" "}
                {result.duration != null
                  ? `${result.duration.toFixed(1)} 秒`
                  : "时长未提供"}
              </p>
              <a
                className="primary download"
                href={result.download_url}
                download
                onClick={() =>
                  setNotice("已交给浏览器下载，请查看浏览器的下载列表。")
                }
              >
                ↓ 下载到本地
              </a>
              <a
                className="source"
                href={`https://www.douyin.com/video/${result.id}`}
                target="_blank"
                rel="noreferrer"
              >
                在抖音查看原作品 ↗
              </a>
            </>
          ) : (
            <div className="empty">
              <div className="film">
                <span>▷</span>
              </div>
              <p>解析后，视频会出现在这里</p>
              <small>先预览，再决定保存</small>
            </div>
          )}
        </section>
      </div>
      <section className="guide">
        <div>
          <b>1</b>
          <p>
            复制分享链接<small>抖音 → 分享 → 复制链接</small>
          </p>
        </div>
        <div>
          <b>2</b>
          <p>
            粘贴并解析<small>整段分享文案也可以</small>
          </p>
        </div>
        <div>
          <b>3</b>
          <p>
            下载到手机<small>在浏览器下载列表中查看</small>
          </p>
        </div>
      </section>
      <footer>
        <p>只保存你拥有或获准下载的作品，尊重创作者。</p>
        <p>添加到主屏幕，即可像 App 一样使用 · 在线解析需要网络</p>
      </footer>
    </main>
  );
}
createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
if ("serviceWorker" in navigator && import.meta.env.PROD)
  navigator.serviceWorker.register("/sw.js").catch(() => {});
