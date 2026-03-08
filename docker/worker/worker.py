"""
Automation worker.

Runs a browser-based demo flow against the VB Bank demo portal:
log in, navigate to transaction history, export CSV, upload evidence to
S3, and report the result back to Step Functions via the task token callback.
When LOCAL_MODE is enabled, the worker skips AWS orchestration callbacks,
loads task input from local env/file, writes evidence locally, and runs with
HEADLESS forced off for easier debugging.
"""

import json
import os
import shutil
import sys
import threading
import time
from pathlib import Path

# Load .env file when running locally (no-op if not installed or file missing)
try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).parent / ".env")
except ImportError:
    pass

from selenium_stealth import stealth

import boto3
from selenium import webdriver
from selenium.common.exceptions import TimeoutException, WebDriverException
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

LOCAL_MODE = os.environ.get("LOCAL_MODE", "false").lower() == "true"
TASK_ID = os.environ.get("TASK_ID", "local-task")
TABLE_NAME = os.environ.get("JOBS_TABLE", "automation_tasks")
TASK_TOKEN = os.environ.get("SFN_TASK_TOKEN", "")
HEADLESS = os.environ.get("HEADLESS", "false" if LOCAL_MODE else "true").lower() == "true"
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
HEARTBEAT_SECONDS = max(30, int(os.environ.get("SFN_HEARTBEAT_SECONDS", "300")))
ARTIFACTS_BUCKET = os.environ.get("ARTIFACTS_BUCKET", "")
PORTAL_BASE_URL = os.environ.get("PORTAL_BASE_URL", "https://vb-bank-demo.vercel.app/login")
APP_PASSWORD = os.environ.get("APP_PASSWORD", "")
LOCAL_TASK_FILE = os.environ.get("LOCAL_TASK_FILE", "")
LOCAL_TASK_JSON = os.environ.get("LOCAL_TASK_JSON", "")
DOWNLOAD_DIR = Path("/tmp/downloads")
SCREENSHOT_PATH = Path("/tmp/final-screenshot.png")
LOCAL_OUTPUT_DIR = Path(os.environ.get("LOCAL_OUTPUT_DIR", "/tmp/automation-output"))


def heartbeat_interval(heartbeat_seconds: int) -> int:
    return max(30, min(60, heartbeat_seconds // 3))


def heartbeat_loop(sfn, stop_event: threading.Event) -> None:
    interval = heartbeat_interval(HEARTBEAT_SECONDS)
    while not stop_event.wait(interval):
        sfn.send_task_heartbeat(taskToken=TASK_TOKEN)
        print(f"[worker] Sent heartbeat for task_id={TASK_ID}")


def report_success(sfn) -> None:
    output = json.dumps({"task_id": TASK_ID, "status": "SUCCEEDED"})
    sfn.send_task_success(taskToken=TASK_TOKEN, output=output)
    print(f"[worker] Reported success for task_id={TASK_ID}")


def report_failure(sfn, exc: Exception) -> None:
    cause = str(exc)[:32768] or exc.__class__.__name__
    sfn.send_task_failure(
        taskToken=TASK_TOKEN,
        error="AutomationError",
        cause=cause,
    )
    print(f"[worker] Reported failure for task_id={TASK_ID}: {cause}", file=sys.stderr)


def get_task(table, task_id: str) -> dict:
    resp = table.get_item(Key={"task_id": task_id})
    item = resp.get("Item")
    if not item:
        raise ValueError(f"Task {task_id} not found in {TABLE_NAME}")
    return item


def get_local_task() -> dict:
    if LOCAL_TASK_JSON:
        task = json.loads(LOCAL_TASK_JSON)
    elif LOCAL_TASK_FILE:
        task = json.loads(Path(LOCAL_TASK_FILE).read_text(encoding="utf-8"))
    else:
        task = {
            "task_id": TASK_ID,
            "payload": {
                "portal": "vb_bank",
                "username": os.environ.get("APP_USERNAME", "john.doe"),
                "account_name": "John Doe",
                "s3_prefix": f"automation/{TASK_ID}",
            },
        }

    task.setdefault("task_id", TASK_ID)
    task.setdefault("payload", {})
    return task


def payload_for(task: dict) -> dict:
    payload = task.get("payload", {})
    if isinstance(payload, str):
        payload = json.loads(payload)
    return payload


def output_prefix(task: dict) -> str:
    payload = payload_for(task)
    prefix = payload.get("s3_prefix") or f"automation/{TASK_ID}"
    return prefix.strip("/")


def build_driver() -> webdriver.Chrome:
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
    options = Options()
    chrome_bin = os.environ.get("CHROME_BIN", "")
    if chrome_bin:
        options.binary_location = chrome_bin
    elif sys.platform == "darwin":
        macos_chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        if os.path.exists(macos_chrome):
            options.binary_location = macos_chrome
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-gpu")
    options.add_argument("--window-size=1440,900")
    options.add_argument("--disable-blink-features=AutomationControlled")
    options.add_argument(
        "user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/131.0.0.0 Safari/537.36"
    )
    options.add_experimental_option("excludeSwitches", ["enable-automation"])
    options.add_experimental_option("useAutomationExtension", False)
    if HEADLESS:
        options.add_argument("--headless=new")

    options.add_experimental_option("prefs", {
        "download.default_directory": str(DOWNLOAD_DIR),
        "download.prompt_for_download": False,
        "download.directory_upgrade": True,
        "safebrowsing.enabled": True,
    })

    chromedriver_bin = os.environ.get("CHROMEDRIVER_BIN", "")
    service = Service(chromedriver_bin) if chromedriver_bin else Service()
    driver = webdriver.Chrome(service=service, options=options)
    driver.set_page_load_timeout(60)
    stealth(driver,
        languages=["en-US", "en"],
        vendor="Google Inc.",
        platform="Win32",
        webgl_vendor="Intel Inc.",
        renderer="Intel Iris OpenGL Engine",
        fix_hairline=True,
    )
    return driver


def wait_for_download(timeout_seconds: int = 30) -> Path:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        csvs = sorted(DOWNLOAD_DIR.glob("*.csv"))
        partials = list(DOWNLOAD_DIR.glob("*.crdownload"))
        if csvs and not partials:
            return csvs[-1]
        time.sleep(0.5)
    raise TimeoutException("Timed out waiting for transaction CSV download")


def upload_artifact(s3_client, local_path: Path, key: str) -> str:
    s3_client.upload_file(str(local_path), ARTIFACTS_BUCKET, key)
    return f"s3://{ARTIFACTS_BUCKET}/{key}"


def save_local_artifact(local_path: Path, destination: Path) -> str:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(local_path, destination)
    return str(destination)


def save_local_evidence(task: dict, csv_path: Path | None, screenshot_path: Path | None) -> dict:
    prefix = output_prefix(task)
    target_dir = LOCAL_OUTPUT_DIR / prefix
    uploaded: dict[str, str] = {}
    if csv_path and csv_path.exists():
        uploaded["transactions"] = save_local_artifact(csv_path, target_dir / csv_path.name)
    if screenshot_path and screenshot_path.exists():
        uploaded["screenshot"] = save_local_artifact(screenshot_path, target_dir / screenshot_path.name)

    payload = payload_for(task)
    metadata_path = target_dir / "result.json"
    metadata_path.write_text(json.dumps({
        "task_id": TASK_ID,
        "portal": payload.get("portal", "vb_bank"),
        "username": payload.get("username", ""),
        "uploaded": uploaded,
        "timestamp": int(time.time()),
        "local_mode": True,
    }, indent=2), encoding="utf-8")
    uploaded["metadata"] = str(metadata_path)
    return uploaded


def upload_evidence(s3_client, task: dict, csv_path: Path | None, screenshot_path: Path | None) -> dict:
    prefix = output_prefix(task)
    uploaded: dict[str, str] = {}
    if csv_path and csv_path.exists():
        uploaded["transactions"] = upload_artifact(s3_client, csv_path, f"{prefix}/{csv_path.name}")
    if screenshot_path and screenshot_path.exists():
        uploaded["screenshot"] = upload_artifact(s3_client, screenshot_path, f"{prefix}/{screenshot_path.name}")

    payload = payload_for(task)
    metadata_path = Path("/tmp/result.json")
    metadata_path.write_text(json.dumps({
        "task_id": TASK_ID,
        "portal": payload.get("portal", "vb_bank"),
        "username": payload.get("username", ""),
        "uploaded": uploaded,
        "timestamp": int(time.time()),
    }, indent=2), encoding="utf-8")
    uploaded["metadata"] = upload_artifact(s3_client, metadata_path, f"{prefix}/result.json")
    return uploaded


def login(wait: WebDriverWait, driver: webdriver.Chrome, task: dict) -> None:
    payload = payload_for(task)
    username = payload.get("username") or os.environ.get("APP_USERNAME", "")
    if not username or not APP_PASSWORD:
        raise ValueError("username (task payload) and APP_PASSWORD must be set")
    print(f"[worker] Login: navigating to {PORTAL_BASE_URL} as {username}")
    driver.get(PORTAL_BASE_URL)
    print(f"[worker] Login: page loaded url={driver.current_url}")
    username_field = wait.until(
        EC.presence_of_element_located((By.CSS_SELECTOR, '[data-testid="input-username"]'))
    )
    password_field = driver.find_element(By.CSS_SELECTOR, '[data-testid="input-password"]')
    username_field.clear()
    username_field.send_keys(username)
    password_field.clear()
    password_field.send_keys(APP_PASSWORD)
    driver.find_element(By.CSS_SELECTOR, '[data-testid="btn-login"]').click()
    print(f"[worker] Login: submitted, waiting for dashboard")
    wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, '[data-testid="balance-amount"]')))
    print(f"[worker] Login: success url={driver.current_url}")


def navigate_to_history(driver: webdriver.Chrome, wait: WebDriverWait) -> None:
    base_url = PORTAL_BASE_URL.rsplit("/", 1)[0]  # strips /login → https://vb-bank-demo.vercel.app
    driver.get(f"{base_url}/history")
    wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, '[data-testid="btn-export-csv"]')))
    print(f"[worker] History page loaded: {driver.current_url}")


def export_csv(wait: WebDriverWait) -> Path:
    wait.until(EC.element_to_be_clickable((By.CSS_SELECTOR, '[data-testid="btn-export-csv"]'))).click()
    print("[worker] CSV export clicked, waiting for download")
    return wait_for_download()


def logout(wait: WebDriverWait) -> None:
    try:
        wait.until(
            EC.element_to_be_clickable((By.CSS_SELECTOR, '[data-testid="btn-logout"]'))
        ).click()
        print("[worker] Logout: success")
    except Exception:
        print("[worker] Logout control not found; continuing", file=sys.stderr)


def run_automation(task: dict) -> None:
    print(f"[worker] Processing task_id={task['task_id']} dry_run={DRY_RUN} headless={HEADLESS}")
    if DRY_RUN:
        print("[worker] Dry-run mode — skipping submission")
        return

    driver = None
    s3_client = None if LOCAL_MODE else boto3.client("s3")
    csv_path = None

    try:
        if DOWNLOAD_DIR.exists():
            shutil.rmtree(DOWNLOAD_DIR)
        DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)

        driver = build_driver()
        wait = WebDriverWait(driver, 30)

        print(f"[worker] Step: login")
        login(wait, driver, task)
        print(f"[worker] Step: navigate_to_history")
        navigate_to_history(driver, wait)
        print(f"[worker] Step: export_csv")
        csv_path = export_csv(wait)
        print(f"[worker] Step: export complete path={csv_path}")
        driver.save_screenshot(str(SCREENSHOT_PATH))
        uploaded = (
            save_local_evidence(task, csv_path, SCREENSHOT_PATH)
            if LOCAL_MODE
            else upload_evidence(s3_client, task, csv_path, SCREENSHOT_PATH)
        )
        print(f"[worker] Uploaded evidence: {json.dumps(uploaded)}")
        logout(wait)
    except Exception as exc:
        print(f"[worker] EXCEPTION {type(exc).__name__}: {exc}", file=sys.stderr)
        if driver:
            try:
                print(f"[worker] Failure url={driver.current_url} title={driver.title}", file=sys.stderr)
                fail_shot = Path("/tmp/failure-screenshot.png")
                driver.save_screenshot(str(fail_shot))
                if not LOCAL_MODE and s3_client and fail_shot.exists():
                    prefix = output_prefix(task)
                    s3_client.upload_file(str(fail_shot), ARTIFACTS_BUCKET, f"{prefix}/failure-screenshot.png")
                    print(f"[worker] Failure screenshot uploaded to s3://{ARTIFACTS_BUCKET}/{prefix}/failure-screenshot.png", file=sys.stderr)
            except Exception:
                pass
        raise
    finally:
        if driver:
            driver.quit()


def main() -> None:
    if LOCAL_MODE:
        task = get_local_task()
        run_automation(task)
        print(f"[worker] Local task {task['task_id']} completed successfully")
        return

    dynamodb = boto3.resource("dynamodb")
    sfn = boto3.client("stepfunctions")
    table = dynamodb.Table(TABLE_NAME)
    stop_event = threading.Event()
    heartbeat_thread = threading.Thread(
        target=heartbeat_loop,
        args=(sfn, stop_event),
        daemon=True,
    )

    heartbeat_thread.start()

    try:
        task = get_task(table, TASK_ID)
        run_automation(task)
        stop_event.set()
        heartbeat_thread.join(timeout=5)
        report_success(sfn)
        print(f"[worker] Task {TASK_ID} completed successfully")
    except Exception as exc:
        stop_event.set()
        heartbeat_thread.join(timeout=5)
        print(f"[worker] ERROR: {exc}", file=sys.stderr)
        try:
            report_failure(sfn, exc)
        except Exception as callback_exc:
            print(f"[worker] Failed to send failure callback: {callback_exc}", file=sys.stderr)
        return


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        import traceback
        traceback.print_exc()
        print(f"[worker] FATAL: {exc}", file=sys.stderr)
        sys.exit(1)
