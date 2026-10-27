// 本地预览：把 docs/ 作为站点根目录挂在 8080，零依赖。
// npm run preview 调用本脚本；改完 fragments/pages 后先 npm run build。
import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const root = path.resolve("docs");
const types = {
  ".html": "text/html; charset=utf-8",
  ".md": "text/markdown; charset=utf-8",
  ".json": "application/json",
  ".css": "text/css",
  ".js": "text/javascript",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".woff2": "font/woff2",
};

http
  .createServer((req, res) => {
    const rel = decodeURIComponent(req.url.split("?")[0]);
    const file = path.join(root, rel);
    if (!file.startsWith(root)) {
      res.writeHead(403).end("forbidden");
      return;
    }
    const target = fs.existsSync(file) && fs.statSync(file).isDirectory() ? path.join(file, "index.html") : file;
    if (!fs.existsSync(target)) {
      res.writeHead(404).end("not found");
      return;
    }
    res.writeHead(200, { "content-type": types[path.extname(target)] ?? "application/octet-stream" });
    fs.createReadStream(target).pipe(res);
  })
  .listen(8080, "127.0.0.1", () => console.log("preview: http://127.0.0.1:8080/"));
