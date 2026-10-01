"""uosc 界面验证：启动 mpv → 等 UI 初始化 → 截屏 → 发送右键 → 再截屏"""
import subprocess, time, os, sys, ctypes, win32api
import win32gui, win32con, win32process
import win32com.client
from PIL import ImageGrab

PKG = r"D:\ClaudeCode\MPV\mpv-lazy-ng\dist\mpv-lazy-ng-20261001-mpv0.41.0\mpv-lazy-ng"
OUT = r"D:\ClaudeCode\MPV\mpv-lazy-ng\_ui_check"
os.makedirs(OUT, exist_ok=True)

PKGR = None
proc = subprocess.Popen([
    PKG + r"\mpv.exe", "av://lavfi:testsrc2",
    "--pause=yes", "--frames=9000", "--geometry=1100x700",
    "--title=UOSC-TEST",
], cwd=PKG, creationflags=0x10)
time.sleep(7)  # 等 uosc 完全初始化

def shot(name):
    ImageGrab.grab().save(os.path.join(OUT, name))
    print("saved", name)

def find_win(pid):
    hits = []
    def cb(hwnd, _):
        _, wpid = win32process.GetWindowThreadProcessId(hwnd)
        if wpid == pid and win32gui.IsWindowVisible(hwnd) and win32gui.GetWindowText(hwnd):
            hits.append(hwnd)
    win32gui.EnumWindows(cb, None)
    return hits

hw = find_win(proc.pid)
if not hw:
    print("FAIL: 无窗口"); proc.kill(); sys.exit(1)
h = hw[0]
try:
    win32gui.ShowWindow(h, win32con.SW_SHOW)
    # 先附加到前台线程再设置，规避 SetForegroundWindow 限制
    user32 = ctypes.windll.user32
    fg = user32.GetForegroundWindow()
    fg_thread = user32.GetWindowThreadProcessId(fg, None)
    cur_thread = ctypes.windll.kernel32.GetCurrentThreadId()
    user32.AttachThreadInput(fg_thread, cur_thread, True)
    win32gui.SetForegroundWindow(h)
    user32.AttachThreadInput(fg_thread, cur_thread, False)
except Exception as e:
    print("foreground warn:", e)
win32gui.SetWindowPos(h, win32con.HWND_TOPMOST, 60, 60, 0, 0, win32con.SWP_NOSIZE)
time.sleep(1)
shot("1_uosc_ui.png")

# 右键（窗口中心）
rect = win32gui.GetWindowRect(h)
cx, cy = (rect[0]+rect[2])//2, (rect[1]+rect[3])//2
win32api_move = win32com.client.Dispatch("WScript.Shell")
win32api.SetCursorPos((cx, cy))
time.sleep(0.3)
shell = win32com.client.Dispatch("WScript.Shell")
shell.SendKeys("{APPSKEY}")  # 模拟右键菜单键
time.sleep(1.2)
shot("2_rightclick_menu.png")

# APPSKEY 若无效，直接发 MBTN_RIGHT 给 mpv（uosc 接管右键）——用进程内 keypress 不可行，改鼠标事件
import ctypes
ctypes.windll.user32.mouse_event(0x0008, 0, 0, 0, 0)  # RIGHTDOWN
ctypes.windll.user32.mouse_event(0x0010, 0, 0, 0, 0)  # RIGHTUP
time.sleep(1.2)
shot("3_rightclick_real.png")

proc.kill()
print("done")
