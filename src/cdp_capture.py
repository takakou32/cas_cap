"""
CAS Cap - CDP経由でEdgeにアタッチし、ブラウザ操作＋スクリーンショットを取得する

前提:
  1. Edgeを全プロセス終了
  2. scripts/start_edge.ps1 でデバッグポート付きEdgeを起動
  3. exeからアプリを起動（Edgeにタブが追加される）
  4. このスクリプトを実行
"""

import asyncio
import argparse
import sys
from datetime import datetime
from pathlib import Path

import yaml
from playwright.async_api import async_playwright


def load_config(config_path: str = "config/config.yaml") -> dict:
    """設定ファイルを読み込む"""
    path = Path(config_path)
    if not path.exists():
        print(f"設定ファイルが見つかりません: {config_path}")
        print("config/config.sample.yaml をコピーして config/config.yaml を作成してください")
        sys.exit(1)
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


async def list_tabs(cdp_url: str):
    """接続中のEdgeのタブ一覧を表示する"""
    async with async_playwright() as p:
        browser = await p.chromium.connect_over_cdp(cdp_url)
        print(f"接続成功。コンテキスト数: {len(browser.contexts)}")
        for ctx in browser.contexts:
            for i, page in enumerate(ctx.pages):
                print(f"  [{i}] {page.title}")
                print(f"      {page.url}")
        browser.close()


async def find_target_page(browser, target_url_keyword: str):
    """URLキーワードに一致するタブを探す"""
    for ctx in browser.contexts:
        for page in ctx.pages:
            if target_url_keyword in page.url:
                return page
    return None


async def capture(config: dict):
    """メインのキャプチャ処理"""
    cdp_url = config.get("cdp_url", "http://localhost:9222")
    target_keyword = config.get("target_url_keyword", "")
    output_dir = Path(config.get("output_dir", "output"))
    full_page = config.get("full_page", True)
    wait_state = config.get("wait_state", "networkidle")
    pages_config = config.get("pages", [])

    output_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    async with async_playwright() as p:
        browser = await p.chromium.connect_over_cdp(cdp_url)
        print(f"Edge接続成功")

        # 対象タブを探す
        target_page = await find_target_page(browser, target_keyword)
        if target_page is None:
            print(f"対象タブが見つかりません (keyword: {target_keyword})")
            print("タブ一覧:")
            for ctx in browser.contexts:
                for page in ctx.pages:
                    print(f"  {page.url}")
            browser.close()
            sys.exit(1)

        print(f"対象タブ: {target_page.title}")
        await target_page.wait_for_load_state(wait_state)

        if not pages_config:
            # ページ設定がなければ現在の画面をキャプチャ
            filename = output_dir / f"capture_{timestamp}.png"
            await target_page.screenshot(path=str(filename), full_page=full_page)
            print(f"キャプチャ保存: {filename}")
        else:
            # 複数画面を巡回キャプチャ
            for i, page_conf in enumerate(pages_config):
                name = page_conf.get("name", f"page_{i:03d}")
                actions = page_conf.get("actions", [])

                # アクション実行
                for action in actions:
                    await execute_action(target_page, action)

                await target_page.wait_for_load_state(wait_state)

                filename = output_dir / f"{timestamp}_{name}.png"
                await target_page.screenshot(path=str(filename), full_page=full_page)
                print(f"キャプチャ保存: {filename}")

        browser.close()
        print("完了")


async def execute_action(page, action: dict):
    """ページ上でアクションを実行する"""
    action_type = action.get("type")

    if action_type == "click":
        selector = action["selector"]
        await page.click(selector)

    elif action_type == "fill":
        selector = action["selector"]
        value = action["value"]
        await page.fill(selector, value)

    elif action_type == "wait":
        selector = action.get("selector")
        timeout = action.get("timeout", 5000)
        if selector:
            await page.wait_for_selector(selector, timeout=timeout)
        else:
            await page.wait_for_timeout(timeout)

    elif action_type == "goto":
        url = action["url"]
        await page.goto(url)

    elif action_type == "select":
        selector = action["selector"]
        value = action["value"]
        await page.select_option(selector, value)

    elif action_type == "keyboard":
        key = action["key"]
        await page.keyboard.press(key)

    else:
        print(f"  未知のアクション: {action_type}")


def main():
    parser = argparse.ArgumentParser(description="CAS Cap - CDP経由ブラウザキャプチャツール")
    parser.add_argument("-c", "--config", default="config/config.yaml", help="設定ファイルパス")
    parser.add_argument("--list", action="store_true", help="タブ一覧を表示")
    parser.add_argument("--cdp-url", default=None, help="CDPのURL (デフォルト: config参照)")
    args = parser.parse_args()

    if args.list:
        cdp_url = args.cdp_url or "http://localhost:9222"
        asyncio.run(list_tabs(cdp_url))
    else:
        config = load_config(args.config)
        if args.cdp_url:
            config["cdp_url"] = args.cdp_url
        asyncio.run(capture(config))


if __name__ == "__main__":
    main()
