#!/usr/bin/env node
/*
 * CAS Cap (JavaScript版) - CDP経由でEdgeにアタッチし、ブラウザ操作＋スクリーンショットを取得する
 *
 * 前提:
 *   1. Edgeを全プロセス終了
 *   2. scripts/start_edge.ps1 でデバッグポート付きEdgeを起動
 *   3. exeからアプリを起動（Edgeにタブが追加される）
 *   4. このスクリプトを実行: node js/cdp_capture.js
 */

"use strict";

const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright");

/** 設定ファイル（JSON）を読み込む */
function loadConfig(configPath) {
  if (!fs.existsSync(configPath)) {
    console.error(`設定ファイルが見つかりません: ${configPath}`);
    console.error("config/config.sample.json をコピーして config/config.json を作成してください");
    process.exit(1);
  }
  return JSON.parse(fs.readFileSync(configPath, "utf-8"));
}

/** YYYYMMDD_HHMMSS 形式のタイムスタンプ */
function timestamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return (
    `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}_` +
    `${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`
  );
}

/** 接続中のEdgeのタブ一覧を表示する */
async function listTabs(cdpUrl) {
  const browser = await chromium.connectOverCDP(cdpUrl);
  const contexts = browser.contexts();
  console.log(`接続成功。コンテキスト数: ${contexts.length}`);
  for (const ctx of contexts) {
    const pages = ctx.pages();
    for (let i = 0; i < pages.length; i++) {
      console.log(`  [${i}] ${await pages[i].title()}`);
      console.log(`      ${pages[i].url()}`);
    }
  }
  await browser.close();
}

/** URLキーワードに一致するタブを探す */
function findTargetPage(browser, targetKeyword) {
  for (const ctx of browser.contexts()) {
    for (const page of ctx.pages()) {
      if (page.url().includes(targetKeyword)) {
        return page;
      }
    }
  }
  return null;
}

/** ページ上でアクションを実行する */
async function executeAction(page, action) {
  switch (action.type) {
    case "click":
      await page.click(action.selector);
      break;
    case "fill":
      await page.fill(action.selector, action.value);
      break;
    case "wait":
      if (action.selector) {
        await page.waitForSelector(action.selector, { timeout: action.timeout ?? 5000 });
      } else {
        await page.waitForTimeout(action.timeout ?? 5000);
      }
      break;
    case "goto":
      await page.goto(action.url);
      break;
    case "select":
      await page.selectOption(action.selector, action.value);
      break;
    case "keyboard":
      await page.keyboard.press(action.key);
      break;
    default:
      console.log(`  未知のアクション: ${action.type}`);
  }
}

/** メインのキャプチャ処理 */
async function capture(config) {
  const cdpUrl = config.cdp_url ?? "http://localhost:9222";
  const targetKeyword = config.target_url_keyword ?? "";
  const outputDir = config.output_dir ?? "output";
  const fullPage = config.full_page ?? true;
  const waitState = config.wait_state ?? "networkidle";
  const pagesConfig = config.pages ?? [];

  fs.mkdirSync(outputDir, { recursive: true });
  const ts = timestamp();

  const browser = await chromium.connectOverCDP(cdpUrl);
  console.log("Edge接続成功");

  const targetPage = findTargetPage(browser, targetKeyword);
  if (targetPage === null) {
    console.error(`対象タブが見つかりません (keyword: ${targetKeyword})`);
    console.error("タブ一覧:");
    for (const ctx of browser.contexts()) {
      for (const page of ctx.pages()) {
        console.error(`  ${page.url()}`);
      }
    }
    await browser.close();
    process.exit(1);
  }

  console.log(`対象タブ: ${await targetPage.title()}`);
  await targetPage.waitForLoadState(waitState);

  if (pagesConfig.length === 0) {
    // ページ設定がなければ現在の画面をキャプチャ
    const filename = path.join(outputDir, `capture_${ts}.png`);
    await targetPage.screenshot({ path: filename, fullPage });
    console.log(`キャプチャ保存: ${filename}`);
  } else {
    // 複数画面を巡回キャプチャ
    for (let i = 0; i < pagesConfig.length; i++) {
      const pageConf = pagesConfig[i];
      const name = pageConf.name ?? `page_${String(i).padStart(3, "0")}`;
      const actions = pageConf.actions ?? [];

      for (const action of actions) {
        await executeAction(targetPage, action);
      }

      await targetPage.waitForLoadState(waitState);

      const filename = path.join(outputDir, `${ts}_${name}.png`);
      await targetPage.screenshot({ path: filename, fullPage });
      console.log(`キャプチャ保存: ${filename}`);
    }
  }

  await browser.close();
  console.log("完了");
}

/** コマンドライン引数をパースする */
function parseArgs(argv) {
  const args = { config: "config/config.json", list: false, cdpUrl: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "-c" || a === "--config") args.config = argv[++i];
    else if (a === "--list") args.list = true;
    else if (a === "--cdp-url") args.cdpUrl = argv[++i];
    else if (a === "-h" || a === "--help") {
      console.log("使い方: node cdp_capture.js [-c config.json] [--list] [--cdp-url URL]");
      process.exit(0);
    }
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.list) {
    const cdpUrl = args.cdpUrl ?? "http://localhost:9222";
    await listTabs(cdpUrl);
  } else {
    const config = loadConfig(args.config);
    if (args.cdpUrl) config.cdp_url = args.cdpUrl;
    await capture(config);
  }
}

main().catch((err) => {
  console.error(`エラー: ${err.message}`);
  process.exit(1);
});
