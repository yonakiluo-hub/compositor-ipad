"""Small Windows control panel; service work never runs on Tk's event thread."""

from __future__ import annotations

from dataclasses import replace
from datetime import datetime
from pathlib import Path
import os
import queue
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from typing import Any, Callable

from .config import DEFAULT_CONFIG, LauncherConfig, load_config, save_config
from .network import discover_ipv4, suggest_address
from .service import LauncherError, ServiceManager


_BACKGROUND = "#f3f5f7"
_PAPER = "#ffffff"
_INK = "#202d3b"
_MUTED = "#637183"
_STATES = {
    "ok": ("已就绪", "#18734a"),
    "warning": ("需留意", "#97600d"),
    "error": ("需处理", "#b3323b"),
    "stopped": ("未启动", "#637183"),
}


def _error_message(error: Exception) -> str:
    if isinstance(error, (LauncherError, ValueError)):
        return str(error)
    if isinstance(error, PermissionError):
        return "无法访问所选文件或文件夹，请在设置中换一个可读写的位置。"
    if isinstance(error, OSError):
        return "无法访问文件或启动程序，请检查设置中的路径是否仍然有效。"
    return "操作未完成。请检查设置，或打开日志文件夹查看服务记录。"


class _LauncherWindow:
    def __init__(self, root: tk.Tk, config_path: Path) -> None:
        self.root = root
        self.config_path = config_path
        self.events: queue.Queue[tuple[Callable, Any, Exception | None]] = queue.Queue()
        self.busy = False
        self.last_status: dict[str, Any] = {}
        self.config_window: tk.Toplevel | None = None
        self.action_buttons: list[ttk.Button] = []
        self.detail_labels: list[tk.Label] = []
        self.load_error: Exception | None = None
        try:
            self.config = load_config(config_path)
        except Exception as error:
            self.config = LauncherConfig()
            self.load_error = error

        root.title("Compositor · Windows 绘画助手")
        root.geometry("790x700")
        root.minsize(700, 620)
        root.configure(background=_BACKGROUND)
        root.protocol("WM_DELETE_WINDOW", root.destroy)
        self._build_styles()
        self._build_window()
        root.after(80, self._drain_events)
        if self.load_error:
            self.summary.set("启动设置需要修正")
            self._render_checks([
                {"name": "本机设置", "state": "error", "message": _error_message(self.load_error)}
            ])
            root.after(150, self._open_settings)
        else:
            root.after(150, self._refresh)

    def _build_styles(self) -> None:
        style = ttk.Style(self.root)
        style.theme_use("clam")
        style.configure("TButton", font=("Microsoft YaHei UI", 10), padding=(12, 8))
        style.configure("TEntry", padding=7, font=("Microsoft YaHei UI", 10))
        style.configure("TCombobox", padding=7, font=("Microsoft YaHei UI", 10))
        style.configure(
            "Primary.TButton", background="#246a59", foreground="white", borderwidth=0,
            padding=(18, 10), font=("Microsoft YaHei UI", 10, "bold"),
        )
        style.map(
            "Primary.TButton", background=[("disabled", "#cbd7d3"), ("active", "#1e584b")],
            foreground=[("disabled", "#65736f"), ("!disabled", "white")],
        )
        style.configure("TProgressbar", background="#246a59", troughcolor="#e7ecef")

    def _label(self, parent: tk.Misc, text: str = "", **kwargs: Any) -> tk.Label:
        label = tk.Label(
            parent, text=text, bg=parent.cget("background"), fg=_INK,
            font=("Microsoft YaHei UI", 10), **kwargs,
        )
        if "wraplength" in kwargs:
            label.bind("<Configure>", lambda event: label.configure(wraplength=max(1, event.width - 4)))
        return label

    def _button(self, parent: tk.Misc, text: str, command: Callable, **kwargs: Any) -> ttk.Button:
        button = ttk.Button(parent, text=text, command=command, **kwargs)
        self.action_buttons.append(button)
        return button

    def _build_window(self) -> None:
        body = tk.Frame(self.root, background=_BACKGROUND, padx=26, pady=22)
        body.pack(fill="both", expand=True)
        body.columnconfigure(0, weight=1)
        body.rowconfigure(4, weight=1)
        header = tk.Frame(body, background=_BACKGROUND)
        header.grid(row=0, column=0, sticky="ew", pady=(0, 18))
        title = self._label(header, "Windows 绘画助手", anchor="w")
        title.configure(font=("Microsoft YaHei UI", 21, "bold"))
        title.pack(side="left")
        self._button(header, "设置", self._open_settings).pack(side="right")
        subtitle = self._label(body, "为 iPad 提供 AI 生成与工程备份", anchor="w")
        subtitle.configure(fg=_MUTED)
        subtitle.grid(row=1, column=0, sticky="ew", pady=(0, 20))

        hero = tk.Frame(body, background=_PAPER, padx=18, pady=16)
        hero.grid(row=2, column=0, sticky="ew")
        self.summary = tk.StringVar(value="正在准备连接检查…")
        summary_label = self._label(hero, textvariable=self.summary, anchor="w", justify="left", wraplength=650)
        summary_label.configure(font=("Microsoft YaHei UI", 14, "bold"))
        summary_label.pack(fill="x")
        self.updated = tk.StringVar(value="先检查现有服务；点击“启动服务”即可启动缺少的服务。")
        updated_label = self._label(hero, textvariable=self.updated, anchor="w", justify="left", wraplength=650)
        updated_label.configure(fg=_MUTED, font=("Microsoft YaHei UI", 9))
        updated_label.pack(fill="x", pady=(8, 0))
        self.progress = ttk.Progressbar(body, mode="indeterminate")
        self.progress.grid(row=3, column=0, sticky="ew", pady=(0, 8))

        checks_area = tk.Frame(body, background=_PAPER)
        checks_area.grid(row=4, column=0, sticky="nsew")
        self.check_canvas = tk.Canvas(checks_area, bg=_PAPER, highlightthickness=0, height=220)
        scrollbar = ttk.Scrollbar(checks_area, orient="vertical", command=self.check_canvas.yview)
        self.check_canvas.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side="right", fill="y")
        self.check_canvas.pack(side="left", fill="both", expand=True)
        self.check_frame = tk.Frame(self.check_canvas, background=_PAPER)
        self.check_window = self.check_canvas.create_window((0, 0), window=self.check_frame, anchor="nw")
        self.check_frame.bind("<Configure>", lambda _event: self.check_canvas.configure(scrollregion=self.check_canvas.bbox("all")))
        self.check_canvas.bind("<Configure>", self._resize_checks)
        self.check_canvas.bind("<MouseWheel>", self._scroll_checks)
        self._render_checks([{"name": "服务状态", "state": "stopped", "message": "等待检查本机连接。"}])

        address_area = tk.Frame(body, background=_BACKGROUND)
        address_area.grid(row=5, column=0, sticky="ew", pady=(18, 0))
        self._label(address_area, "iPad 连接地址", anchor="w").pack(fill="x", pady=(0, 6))
        address_row = tk.Frame(address_area, background=_BACKGROUND)
        address_row.pack(fill="x")
        self.address = tk.StringVar(value="检查后显示")
        ttk.Entry(address_row, textvariable=self.address, state="readonly").pack(side="left", fill="x", expand=True)
        self.copy_button = self._button(address_row, "复制地址", self._copy_address)
        self.copy_button.pack(side="right", padx=(8, 0))

        actions = tk.Frame(body, background=_BACKGROUND)
        actions.grid(row=6, column=0, sticky="ew", pady=(18, 0))
        self._button(actions, "启动服务", self._start, style="Primary.TButton").pack(side="left")
        self._button(actions, "检查状态", self._refresh).pack(side="left", padx=(8, 0))
        self.pairing_button = self._button(actions, "配对文件夹", self._open_pairing_folder)
        self.pairing_button.pack(side="right")
        self.logs_button = self._button(actions, "日志", self._open_logs_folder)
        self.logs_button.pack(side="right", padx=(0, 8))
        self.logs_menu = tk.Menu(self.root, tearoff=False, font=("Microsoft YaHei UI", 10))
        self.notice = tk.StringVar(value="关闭此窗口后，已启动的服务继续在后台运行。")
        note = self._label(body, textvariable=self.notice, anchor="w", justify="left", wraplength=680)
        note.configure(fg=_MUTED, font=("Microsoft YaHei UI", 9))
        note.grid(row=7, column=0, sticky="ew", pady=(14, 0))
        self._set_busy(False)

    def _scroll_checks(self, event: tk.Event) -> None:
        self.check_canvas.yview_scroll(-int(event.delta / 120), "units")

    def _resize_checks(self, event: tk.Event) -> None:
        self.check_canvas.itemconfigure(self.check_window, width=event.width)

    def _render_checks(self, checks: list[dict[str, Any]]) -> None:
        for child in self.check_frame.winfo_children():
            child.destroy()
        self.detail_labels.clear()
        for item in checks:
            state_text, color = _STATES.get(item.get("state", "stopped"), _STATES["stopped"])
            card = tk.Frame(self.check_frame, background=_PAPER, padx=18, pady=11)
            card.pack(fill="x")
            heading = tk.Frame(card, background=_PAPER)
            heading.pack(fill="x")
            title = self._label(heading, str(item.get("name", "连接检查")), anchor="w")
            title.configure(font=("Microsoft YaHei UI", 10, "bold"))
            title.pack(side="left")
            state_label = self._label(heading, "●  " + state_text)
            state_label.configure(fg=color, font=("Microsoft YaHei UI", 9))
            state_label.pack(side="right")
            detail = self._label(card, str(item.get("message", "")), anchor="w", justify="left", wraplength=640)
            detail.configure(fg=_MUTED, font=("Microsoft YaHei UI", 9))
            detail.pack(fill="x", pady=(5, 0))
            self.detail_labels.append(detail)
            for widget in (card, heading, title, state_label, detail):
                widget.bind("<MouseWheel>", self._scroll_checks)
            tk.Frame(self.check_frame, background="#eef1f4", height=1).pack(fill="x", padx=18)

    def _set_busy(self, busy: bool) -> None:
        self.busy = busy
        for button in self.action_buttons:
            if button.winfo_exists():
                button.configure(state="disabled" if busy else "normal")
        if not busy:
            self.copy_button.configure(state="normal" if self.last_status.get("base_url") else "disabled")
            self.pairing_button.configure(state="normal" if self.last_status.get("pairing_path") else "disabled")
            self.logs_button.configure(state="normal" if self.last_status.get("logs_dir") or self.config.runtime_dir else "disabled")
            self.progress.stop()
        else:
            self.progress.start(12)

    def _submit(self, operation: Callable[[], Any], completed: Callable[[Any, Exception | None], None]) -> None:
        if self.busy:
            return
        self._set_busy(True)

        def worker() -> None:
            try:
                result = operation()
            except Exception as error:
                self.events.put((completed, None, error))
            else:
                self.events.put((completed, result, None))

        # Finish any startup already requested, even if the user closes the window.
        threading.Thread(target=worker, name="launcher-operation", daemon=False).start()

    def _drain_events(self) -> None:
        try:
            while True:
                completed, result, error = self.events.get_nowait()
                self._set_busy(False)
                completed(result, error)
        except queue.Empty:
            pass
        self.root.after(80, self._drain_events)

    def _refresh(self) -> None:
        self.summary.set("正在检查服务与连接…")
        self.updated.set("检查不会创建 AI 任务，也不会重启正在运行的服务。")
        self._submit(lambda: ServiceManager(self.config).status(), self._show_status)

    def _start(self) -> None:
        if self.load_error:
            self._open_settings()
            return
        self.summary.set("正在启动服务…")
        self.updated.set("首次启动 ComfyUI 可能需要一会儿；已有服务会直接复用。")
        self._submit(lambda: ServiceManager(self.config).start(), self._show_status)

    def _show_status(self, result: Any, error: Exception | None) -> None:
        if error:
            self.summary.set("操作未完成")
            self.updated.set(_error_message(error))
            self._render_checks([{"name": "启动与连接", "state": "error", "message": _error_message(error)}])
            return
        self.last_status = result
        self.summary.set(str(result.get("summary") or ("服务已就绪" if result.get("ready") else "请查看下方检查结果")))
        self.updated.set("上次检查 " + datetime.now().strftime("%H:%M:%S"))
        self.address.set(str(result.get("base_url") or "请在设置中选择局域网地址"))
        self._render_checks(result.get("checks", []))
        self.notice.set("关闭此窗口后，已启动的服务继续在后台运行。")
        self._set_busy(False)

    def _copy_address(self) -> None:
        address = self.last_status.get("base_url")
        if address:
            self.root.clipboard_clear()
            self.root.clipboard_append(str(address))
            self.root.update_idletasks()
            self.notice.set("连接地址已复制。iPad 和 Windows 需要连接同一个局域网。")

    def _open_folder(self, folder: Path) -> None:
        try:
            if not folder.is_dir():
                messagebox.showinfo("文件夹尚未创建", "成功启动服务后会自动创建此文件夹。", parent=self.root)
                return
            os.startfile(str(folder.resolve()))
        except Exception as error:
            messagebox.showerror("无法打开文件夹", _error_message(error), parent=self.root)

    def _open_pairing_folder(self) -> None:
        path = self.last_status.get("pairing_path")
        if path:
            self._open_folder(Path(path).parent)

    def _open_logs_folder(self) -> None:
        bridge_path = self.last_status.get("logs_dir") or self.config.logs_dir
        comfy_path = self.config.runtime_dir
        self.logs_menu.delete(0, "end")
        self.logs_menu.add_command(
            label="桥接日志", command=lambda: self._open_folder(Path(bridge_path)),
            state="normal" if bridge_path else "disabled",
        )
        self.logs_menu.add_command(
            label="ComfyUI 日志", command=lambda: self._open_folder(Path(comfy_path)),
            state="normal" if comfy_path else "disabled",
        )
        try:
            self.logs_menu.tk_popup(
                self.logs_button.winfo_rootx(),
                self.logs_button.winfo_rooty() + self.logs_button.winfo_height(),
            )
        finally:
            self.logs_menu.grab_release()

    def _open_settings(self) -> None:
        if self.busy:
            return
        if self.config_window and self.config_window.winfo_exists():
            self.config_window.lift()
            return
        window = self.config_window = tk.Toplevel(self.root)
        window.title("本机设置")
        window.configure(background=_BACKGROUND)
        window.transient(self.root)
        window.grab_set()
        window.geometry("790x675")
        window.minsize(710, 650)
        frame = tk.Frame(window, background=_BACKGROUND, padx=24, pady=20)
        frame.pack(fill="both", expand=True)
        frame.columnconfigure(0, weight=1)
        frame.rowconfigure(7, weight=1)
        title = self._label(frame, "连接与文件位置", anchor="w")
        title.configure(font=("Microsoft YaHei UI", 16, "bold"))
        title.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        hint = self._label(frame, "已有服务请选择原来的数据文件夹，以保留画稿备份、任务和配对。", anchor="w", wraplength=690, justify="left")
        hint.configure(fg=_MUTED)
        hint.grid(row=1, column=0, sticky="ew", pady=(0, 15))
        fields: dict[str, tk.StringVar] = {}

        def choose_path(key: str) -> None:
            current = Path(fields[key].get()).expanduser()
            initial = current if current.is_dir() else current.parent
            options: dict[str, Any] = {"parent": window}
            if initial.is_dir():
                options["initialdir"] = str(initial)
            if key == "bridge_python":
                value = filedialog.askopenfilename(title="选择桥接环境的 Python", filetypes=[("Python", "python.exe"), ("所有文件", "*.*")], **options)
            else:
                value = filedialog.askdirectory(title="选择文件夹", mustexist=False, **options)
            if value:
                fields[key].set(value)

        paths = (
            ("bridge_python", "桥接运行环境", "选择 Python 文件"),
            ("comfy_install", "ComfyUI 安装文件夹", "选择文件夹"),
            ("models_dir", "模型文件夹", "选择文件夹"),
            ("data_dir", "任务与工程备份", "选择文件夹"),
            ("runtime_dir", "ComfyUI 工作文件夹", "选择文件夹"),
        )
        paths_frame = tk.Frame(frame, background=_BACKGROUND)
        paths_frame.grid(row=2, column=0, sticky="ew")
        paths_frame.columnconfigure(1, weight=1)
        for index, (key, label, browse_label) in enumerate(paths):
            self._label(paths_frame, label, anchor="w").grid(row=index, column=0, sticky="w", padx=(0, 12), pady=5)
            fields[key] = tk.StringVar(value=str(getattr(self.config, key)))
            ttk.Entry(paths_frame, textvariable=fields[key]).grid(row=index, column=1, sticky="ew", pady=5)
            self._button(paths_frame, browse_label, lambda key=key: choose_path(key)).grid(row=index, column=2, sticky="ew", padx=(8, 0), pady=5)

        self._label(frame, "Windows 局域网地址", anchor="w").grid(row=3, column=0, sticky="ew", pady=(12, 3))
        network_row = tk.Frame(frame, background=_BACKGROUND)
        network_row.grid(row=4, column=0, sticky="ew")
        fields["lan_address"] = tk.StringVar(value=self.config.lan_address)
        address_picker = ttk.Combobox(network_row, textvariable=fields["lan_address"])
        address_picker.pack(side="left", fill="x", expand=True)
        network_note = tk.StringVar(value="可从当前网卡选择，也可以直接输入地址。")
        address_choices: dict[str, dict[str, Any]] = {}

        def address_selected(_event: tk.Event) -> None:
            entry = address_choices.get(fields["lan_address"].get())
            if entry:
                fields["lan_address"].set(entry["address"])
                network_note.set("所选网卡：" + entry["name"] + ("（虚拟网卡，请确认 iPad 可以访问）" if entry["virtual"] else ""))

        address_picker.bind("<<ComboboxSelected>>", address_selected)

        def addresses_ready(result: Any, error: Exception | None) -> None:
            if not window.winfo_exists():
                return
            if error:
                network_note.set("暂时无法读取网卡，可手动填写局域网地址。")
                return
            entries = sorted(result, key=lambda entry: (bool(entry.get("virtual")), str(entry.get("name", "")), str(entry["address"])))
            address_choices.clear()
            for entry in entries:
                label = f"{entry['address']}  ·  {entry['name']}" + ("（虚拟）" if entry["virtual"] else "")
                address_choices[label] = entry
            address_picker.configure(values=list(address_choices))
            current = fields["lan_address"].get().strip()
            suggested = suggest_address(result, current)
            if not current and suggested:
                fields["lan_address"].set(suggested)
            physical = [entry for entry in entries if not entry.get("virtual")]
            preferred = physical[0] if physical else (entries[0] if entries else None)
            if preferred:
                network_note.set(f"已发现 {len(entries)} 个地址；优先使用连接 iPad 所在网络的网卡。")
            else:
                network_note.set("未找到可用地址，请先连接 Wi-Fi 或有线网络。")

        def discover() -> None:
            network_note.set("正在读取网卡…")
            self._submit(discover_ipv4, addresses_ready)

        self._button(network_row, "重新查找", discover).pack(side="right", padx=(8, 0))
        network_hint = self._label(frame, textvariable=network_note, anchor="w", wraplength=690, justify="left")
        network_hint.configure(fg=_MUTED, font=("Microsoft YaHei UI", 9))
        network_hint.grid(row=5, column=0, sticky="ew", pady=(4, 8))
        ports = tk.Frame(frame, background=_BACKGROUND)
        ports.grid(row=6, column=0, sticky="ew")
        for key, label in (("bridge_port", "iPad 连接端口"), ("comfy_port", "ComfyUI 本机端口")):
            self._label(ports, label).pack(side="left", padx=(0, 8))
            fields[key] = tk.StringVar(value=str(getattr(self.config, key)))
            ttk.Entry(ports, textvariable=fields[key], width=7).pack(side="left", padx=(0, 20))

        buttons = tk.Frame(frame, background=_BACKGROUND)
        buttons.grid(row=8, column=0, sticky="ew", pady=(15, 0))

        def save() -> None:
            try:
                values: dict[str, Any] = {key: value.get().strip() for key, value in fields.items()}
                for key in ("bridge_port", "comfy_port"):
                    try:
                        values[key] = int(values[key])
                    except ValueError:
                        raise ValueError("端口请填写 1024 到 65535 之间的整数。") from None
                config = replace(self.config, **values)
                save_config(config, self.config_path)
            except Exception as error:
                messagebox.showerror("设置未保存", _error_message(error), parent=window)
                return
            self.config = config
            self.load_error = None
            self.last_status = {}
            self.address.set("检查后显示")
            window.destroy()
            self._refresh()

        self._button(buttons, "保存并检查", save, style="Primary.TButton").pack(side="right")
        self._button(buttons, "取消", window.destroy).pack(side="right", padx=(0, 8))
        window.after(80, discover)


def run_ui(config_path: Path = DEFAULT_CONFIG) -> None:
    """Run the foreground panel; closing it does not stop background services."""
    root = tk.Tk()
    _LauncherWindow(root, Path(config_path))
    root.mainloop()
