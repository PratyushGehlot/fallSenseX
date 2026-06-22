#!/usr/bin/env python3
"""
Professional Radar Configuration Tool (PyQt5)
Modern dark-theme configuration tool for LD6001B radar sensor
Features:
- Fusion dark theme
- Toolbar with quick actions
- Status bar with connection state
- 3-pane layout (Command Library / Sequence Editor / Terminal)
- Progress bar for sequence execution
- Connection LED indicator
- Command presets library
- Save/load command profiles
"""

import sys
import json
import serial
import serial.tools.list_ports
from PyQt5.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QComboBox, QSpinBox, QPushButton, QLabel, QTextEdit, QLineEdit, QGroupBox,
    QTableWidget, QTableWidgetItem, QTreeWidget, QTreeWidgetItem,
    QHeaderView, QSplitter, QProgressBar, QFileDialog, QMessageBox
)
from PyQt5.QtCore import QTimer, Qt, pyqtSignal, QThread
from PyQt5.QtGui import QTextCursor, QColor, QTextCharFormat


def process_cmd(text):
    """Process escape sequences in command text"""
    return text.replace('\\n', '\n').replace('\\r', '\r')


class SerialWorker(QThread):
    """Background thread for serial communication"""
    data_received = pyqtSignal(bytes, bool)
    error_occurred = pyqtSignal(str)

    def __init__(self, port, baudrate):
        super().__init__()
        self.port = port
        self.baudrate = baudrate
        self.serial_conn = None
        self.running = False

    def run(self):
        try:
            self.serial_conn = serial.Serial(
                self.port, self.baudrate, timeout=1, write_timeout=1
            )
            self.running = True
            while self.running:
                if self.serial_conn.in_waiting:
                    data = self.serial_conn.read(self.serial_conn.in_waiting)
                    self.data_received.emit(data, False)
                self.msleep(50)
        except Exception as e:
            self.error_occurred.emit(str(e))

    def send_data(self, data):
        if self.serial_conn and self.serial_conn.is_open:
            try:
                self.serial_conn.write(data)
                self.data_received.emit(data, True)
            except Exception as e:
                self.error_occurred.emit(str(e))

    def stop(self):
        self.running = False
        if self.serial_conn:
            self.serial_conn.close()
        self.quit()
        self.wait()


DARK_THEME = """
QMainWindow { background:#1e1e1e; font-size:11pt; }
QToolBar { background:#252526; spacing:5px; font-size:11pt; }
QToolButton { background:#0E639C; border:none; border-radius:4px; padding:6px 10px; font-size:11pt; }
QToolButton:hover { background:#1177BB; }
QGroupBox {
    border:1px solid #3c3c3c;
    border-radius:8px;
    margin-top:10px;
    padding-top:15px;
    font-weight:bold;
    color:#d4d4d4;
    font-size:11pt;
}
QGroupBox::title {
    subline-offset: 2px;
    padding: 0 5px 0 5px;
    font-size:12pt;
}
QPushButton {
    background:#0E639C;
    border:none;
    border-radius:6px;
    padding:6px 12px;
    color:#ffffff;
    font-size:11pt;
    min-height:24px;
}
QPushButton:hover { background:#1177BB; }
QPushButton:disabled { background:#3c3c3c; }
QLineEdit, QTextEdit, QTableWidget, QTreeWidget, QComboBox {
    background:#1e1e1e;
    border:1px solid #3c3c3c;
    border-radius:5px;
    color:#d4d4d4;
    font-size:11pt;
}
QLabel {
    font-size:11pt;
    color:#d4d4d4;
}
QHeaderView::section {
    background:#252526;
    color:#d4d4d4;
    padding:4px;
    border:1px solid #3c3c3c;
    font-size:11pt;
}
QProgressBar {
    background:#1e1e1e;
    border:1px solid #3c3c3c;
    border-radius:5px;
    text-align:center;
    font-size:11pt;
}
QProgressBar::chunk {
    background:#0E639C;
    border-radius:5px;
}
"""


class ProfessionalRadarTool(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Professional Radar Configuration Tool")
        self.resize(1600, 900)

        self.serial_worker = None
        self.command_sequence = []
        self.running_row = -1
        self.current_seq_index = 0
        self.response_received = False
        self.expected_response = None
        self.current_row_for_single = 0
        self.expected_response_single = None
        self.response_received_single = False

        self.create_toolbar()
        self.create_statusbar()
        self.create_ui()

    def create_toolbar(self):
        tb = self.addToolBar("Main")
        tb.setMovable(False)

        actions = [
            ("Refresh", self.refresh_ports),
            ("Save Profile", self.save_profile),
            ("Load Profile", self.load_profile),
        ]

        for txt, callback in actions:
            action = tb.addAction(txt)
            action.triggered.connect(callback)

    def create_statusbar(self):
        self.status = self.statusBar()
        self.status.showMessage("Disconnected")
        self.status.setStyleSheet("color: #888888; font-size:11pt;")

    def create_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        main_layout = QVBoxLayout(central)
        main_layout.setSpacing(5)
        main_layout.setContentsMargins(5, 5, 5, 5)

        conn = QGroupBox("Connection")
        cl = QHBoxLayout(conn)
        cl.setSpacing(3)
        cl.setContentsMargins(3, 3, 3, 3)

        self.led = QLabel("🔴 Disconnected")
        cl.addWidget(self.led)

        cl.addWidget(QLabel("Port:"))
        self.port_combo = QComboBox()
        self.port_combo.setMinimumWidth(200)
        cl.addWidget(self.port_combo)

        cl.addWidget(QLabel("Baud:"))
        self.baud_combo = QComboBox()
        self.baud_combo.addItems(["9600", "19200", "38400", "57600", "115200", "230400", "460800", "921600"])
        self.baud_combo.setCurrentText("115200")
        cl.addWidget(self.baud_combo)

        self.conn_btn = QPushButton("Connect")
        self.conn_btn.setCheckable(True)
        self.conn_btn.clicked.connect(self.toggle_connection)
        self.conn_btn.toggled.connect(self.on_connect_toggled)
        cl.addWidget(self.conn_btn)

        cl.addWidget(QLabel("Status:"))
        self.status_label = QLabel("Ready")
        self.status_label.setStyleSheet("color:#888888;")
        cl.addWidget(self.status_label)

        cl.addStretch()
        main_layout.addWidget(conn)

        splitter = QSplitter(Qt.Horizontal)

        self.library = QTreeWidget()
        self.library.setHeaderHidden(True)
        self.setup_library()

        self.sequence = QTableWidget(0, 7)
        self.sequence.setHorizontalHeaderLabels(
            ["#", "Command", "Description", "Expected", "Delay (ms)", "Result", "Action"]
        )
        self.sequence.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeToContents)
        self.sequence.horizontalHeader().setSectionResizeMode(1, QHeaderView.Stretch)
        self.sequence.horizontalHeader().setSectionResizeMode(2, QHeaderView.Stretch)
        self.sequence.horizontalHeader().setSectionResizeMode(3, QHeaderView.Stretch)
        self.sequence.horizontalHeader().setSectionResizeMode(4, QHeaderView.ResizeToContents)
        self.sequence.horizontalHeader().setSectionResizeMode(5, QHeaderView.ResizeToContents)
        self.sequence.horizontalHeader().setSectionResizeMode(6, QHeaderView.ResizeToContents)

        right = QWidget()
        rl = QVBoxLayout(right)
        rl.setSpacing(5)

        rl.addWidget(QLabel("Terminal Output (TX = Red, RX = Green)"))

        self.terminal = QTextEdit()
        self.terminal.setReadOnly(True)
        self.terminal.setStyleSheet("background-color:#1e1e1e; color:#d4d4d4; font-family:'Consolas','Courier New',monospace; font-size:11pt;")
        self.terminal.setMinimumHeight(400)
        rl.addWidget(self.terminal)

        self.progress = QProgressBar()
        self.progress.setValue(0)
        self.progress.setFormat("Ready")
        rl.addWidget(self.progress)

        send_layout = QHBoxLayout()
        self.manual_cmd_input = QLineEdit()
        self.manual_cmd_input.setPlaceholderText("Enter AT command...")
        send_layout.addWidget(self.manual_cmd_input)

        self.send_manual_btn = QPushButton("Send")
        self.send_manual_btn.clicked.connect(self.send_manual_command)
        send_layout.addWidget(self.send_manual_btn)

        self.clear_log_btn = QPushButton("Clear Log")
        self.clear_log_btn.clicked.connect(self.clear_terminal)
        send_layout.addWidget(self.clear_log_btn)

        rl.addLayout(send_layout)

        splitter.addWidget(self.library)
        splitter.addWidget(self.sequence)
        splitter.addWidget(right)
        splitter.setSizes([250, 700, 500])

        main_layout.addWidget(splitter)

        btn_layout = QHBoxLayout()
        self.add_cmd_btn = QPushButton("+ Add Command")
        self.add_cmd_btn.clicked.connect(self.add_command)
        btn_layout.addWidget(self.add_cmd_btn)

        self.clear_sequence_btn = QPushButton("Clear Sequence")
        self.clear_sequence_btn.clicked.connect(self.clear_sequence)
        btn_layout.addWidget(self.clear_sequence_btn)

        self.send_seq_btn = QPushButton("Send Sequence")
        self.send_seq_btn.clicked.connect(self.send_sequence)
        btn_layout.addWidget(self.send_seq_btn)

        btn_layout.addStretch()
        main_layout.addLayout(btn_layout)

    def setup_library(self):
        device = QTreeWidgetItem(["📱 Device"])
        device.addChild(QTreeWidgetItem(["AT+VER", "Get firmware version", "OK"]))
        device.addChild(QTreeWidgetItem(["AT+RESET", "Reset device", "OK"]))
        device.addChild(QTreeWidgetItem(["AT+BAUD", "Set baud rate", "OK"]))

        radar = QTreeWidgetItem(["📡 Radar"])
        radar.addChild(QTreeWidgetItem(["AT+START", "Start radar", "OK"]))
        radar.addChild(QTreeWidgetItem(["AT+STOP", "Stop radar", "OK"]))
        radar.addChild(QTreeWidgetItem(["AT+DBG=0", "Disable debug", "OK"]))
        radar.addChild(QTreeWidgetItem(["AT+SENS=3", "Set sensitivity", "OK"]))

        self.library.addTopLevelItem(device)
        self.library.addTopLevelItem(radar)
        self.library.itemClicked.connect(self.add_from_library)

    def add_from_library(self, item, column):
        if item.text(1):
            cmd = item.text(0)
            desc = item.text(1)
            expected = item.text(2) if item.childCount() == 0 else "OK"

            row = self.sequence.rowCount()
            self.sequence.insertRow(row)

            self.sequence.setItem(row, 0, QTableWidgetItem(str(row + 1)))
            self.sequence.setItem(row, 1, QTableWidgetItem(cmd))
            self.sequence.setItem(row, 2, QTableWidgetItem(desc))
            self.sequence.setItem(row, 3, QTableWidgetItem(expected))
            self.sequence.setItem(row, 4, QTableWidgetItem("100"))
            self.sequence.setItem(row, 5, QTableWidgetItem("Pending"))

            send_btn = QPushButton("Send")
            send_btn.clicked.connect(lambda checked, r=row: self.send_single_command(r))
            self.sequence.setCellWidget(row, 6, send_btn)

    def add_command(self):
        row = self.sequence.rowCount()
        self.sequence.insertRow(row)
        self.sequence.setItem(row, 0, QTableWidgetItem(str(row + 1)))
        self.sequence.setItem(row, 1, QTableWidgetItem("AT+"))
        self.sequence.setItem(row, 2, QTableWidgetItem(""))
        self.sequence.setItem(row, 3, QTableWidgetItem("OK"))
        self.sequence.setItem(row, 4, QTableWidgetItem("100"))
        self.sequence.setItem(row, 5, QTableWidgetItem("Pending"))

        send_btn = QPushButton("Send")
        send_btn.clicked.connect(lambda checked, r=row: self.send_single_command(r))
        self.sequence.setCellWidget(row, 6, send_btn)

    def send_single_command(self, row):
        if not self.serial_worker or not self.serial_worker.isRunning():
            self.status_label.setText("Error: Not connected")
            return

        cmd = self.sequence.item(row, 1).text() if self.sequence.item(row, 1) else ""
        expected = self.sequence.item(row, 3).text() if self.sequence.item(row, 3) else ""

        if cmd:
            full_cmd = process_cmd(cmd)
            self.serial_worker.send_data(full_cmd.encode())
            self.sequence.item(row, 5).setText("Sent")

            self.current_row_for_single = row
            self.expected_response_single = expected if expected else None
            self.response_received_single = False

            self.single_timer = QTimer()
            self.single_timer.setSingleShot(True)
            self.single_timer.timeout.connect(self.handle_single_timeout)
            self.single_timer.start(1000)

    def handle_single_timeout(self):
        row = self.current_row_for_single
        if self.expected_response_single and not self.response_received_single:
            self.sequence.item(row, 5).setText("Failed")
            self.status_label.setText("Command failed")
        else:
            self.sequence.item(row, 5).setText("OK")
            self.status_label.setText("Command OK")

    def toggle_connection(self):
        if self.serial_worker and self.serial_worker.isRunning():
            self.disconnect_serial()
        else:
            self.connect_serial()

    def refresh_ports(self):
        self.port_combo.clear()
        ports = serial.tools.list_ports.comports()
        for port in ports:
            self.port_combo.addItem(f"{port.device} - {port.description}")
        if not ports:
            self.port_combo.addItem("No ports found")

    def connect_serial_toolbar(self):
        if self.serial_worker and self.serial_worker.isRunning():
            return
        self.connect_serial()

    def connect_serial(self):
        port_text = self.port_combo.currentText()
        if not port_text or "No ports" in port_text:
            self.status_label.setText("No port selected")
            return

        port = port_text.split(" - ")[0]

        try:
            self.serial_worker = SerialWorker(port, int(self.baud_combo.currentText()))
            self.serial_worker.data_received.connect(self.on_data_received)
            self.serial_worker.error_occurred.connect(self.on_error)
            self.serial_worker.start()

            self.led.setText("🟢 Connected")
            self.led.setStyleSheet("color:green;")
            self.status_label.setText(f"Connected to {port}")
            self.send_seq_btn.setEnabled(True)
            self.log_data(f"[System] Connected to {port} at {self.baud_combo.currentText()} baud\n", QColor(Qt.blue))
        except Exception as e:
            self.on_error(str(e))

    def on_connect_toggled(self, checked):
        if checked:
            self.conn_btn.setText("Disconnect")
        else:
            self.conn_btn.setText("Connect")

    def disconnect_serial(self):
        if self.serial_worker:
            self.serial_worker.stop()
            self.serial_worker = None
        self.led.setText("🔴 Disconnected")
        self.led.setStyleSheet("color:red;")
        self.status_label.setText("Disconnected")
        self.send_seq_btn.setEnabled(False)

    def on_data_received(self, data, is_tx):
        text = data.decode('utf-8', errors='replace')
        color = QColor(Qt.red) if is_tx else QColor(Qt.green)
        self.log_data(text, color)

        if not is_tx and self.expected_response and self.expected_response in text:
            self.response_received = True

        if not is_tx and self.expected_response_single and self.expected_response_single in text:
            self.response_received_single = True

    def on_error(self, error_msg):
        self.led.setText("🔴 Error")
        self.led.setStyleSheet("color:red;")
        self.status_label.setText(error_msg)
        self.serial_worker = None
        QMessageBox.critical(self, "Connection Error", error_msg)

    def log_data(self, text, color):
        cursor = self.terminal.textCursor()
        cursor.movePosition(QTextCursor.End)

        fmt = QTextCharFormat()
        fmt.setForeground(color)
        cursor.setCharFormat(fmt)
        cursor.insertText(text)

        self.terminal.setTextCursor(cursor)
        self.terminal.ensureCursorVisible()

    def send_manual_command(self):
        cmd = self.manual_cmd_input.text().strip()
        if cmd and self.serial_worker and self.serial_worker.isRunning():
            cmd = process_cmd(cmd)
            self.serial_worker.send_data(cmd.encode())
            self.manual_cmd_input.clear()

    def clear_terminal(self):
        self.terminal.clear()

    def clear_sequence(self):
        self.sequence.setRowCount(0)

    def send_sequence(self):
        if not self.serial_worker or not self.serial_worker.isRunning():
            self.status_label.setText("Not connected")
            return

        commands = []
        for row in range(self.sequence.rowCount()):
            cmd = self.sequence.item(row, 1).text() if self.sequence.item(row, 1) else ""
            expected = self.sequence.item(row, 3).text() if self.sequence.item(row, 3) else ""
            delay = int(self.sequence.item(row, 4).text()) if self.sequence.item(row, 4) else 100
            if cmd:
                commands.append((cmd, expected, delay, row))

        if not commands:
            self.status_label.setText("No commands")
            return

        self.send_seq_btn.setEnabled(False)
        self.command_sequence = commands
        self.send_sequence_exec(0)

    def highlight_running_row(self, row):
        brush = QColor(0, 255, 0, 50)
        for col in range(self.sequence.columnCount()):
            item = self.sequence.item(row, col)
            if item:
                item.setBackground(brush)

    def clear_row_highlight(self, row):
        for col in range(self.sequence.columnCount()):
            item = self.sequence.item(row, col)
            if item:
                item.setBackground(QColor(Qt.transparent))

    def send_sequence_exec(self, index):
        if index >= len(self.command_sequence):
            self.send_seq_btn.setEnabled(True)
            self.progress.setFormat("Complete")
            self.progress.setValue(100)
            self.status_label.setText("Sequence completed")
            return

        if self.running_row >= 0:
            self.clear_row_highlight(self.running_row)

        cmd, expected, delay, row = self.command_sequence[index]
        full_cmd = process_cmd(cmd)
        self.serial_worker.send_data(full_cmd.encode())
        self.sequence.item(row, 5).setText("Sent")
        self.highlight_running_row(row)
        self.running_row = row

        self.current_seq_index = index
        self.expected_response = expected if expected else None
        self.response_received = False

        total = len(self.command_sequence)
        progress = int((index + 1) / total * 100)
        self.progress.setValue(progress)
        self.progress.setFormat(f"Command {index + 1}/{total}")

        self.seq_timer = QTimer()
        self.seq_timer.setSingleShot(True)
        self.seq_timer.timeout.connect(lambda: self.handle_timeout(row))
        self.seq_timer.start(1000)

    def handle_timeout(self, row):
        if self.expected_response and not self.response_received:
            self.sequence.item(row, 5).setText("Failed")
        else:
            self.sequence.item(row, 5).setText("OK")

        self.clear_row_highlight(row)

        if self.command_sequence:
            delay = self.command_sequence[self.current_seq_index][2]
            QTimer.singleShot(delay, lambda: self.send_sequence_exec(self.current_seq_index + 1))

    def save_profile(self):
        path, _ = QFileDialog.getSaveFileName(
            self, "Save Profile", "radar_profile.json", "JSON Files (*.json)"
        )
        if not path:
            return

        profile = {"commands": []}
        for row in range(self.sequence.rowCount()):
            cmd = self.sequence.item(row, 1).text() if self.sequence.item(row, 1) else ""
            desc = self.sequence.item(row, 2).text() if self.sequence.item(row, 2) else ""
            expected = self.sequence.item(row, 3).text() if self.sequence.item(row, 3) else ""
            delay = self.sequence.item(row, 4).text() if self.sequence.item(row, 4) else "100"
            if cmd:
                profile["commands"].append({
                    "command": cmd, "description": desc,
                    "expected": expected, "delay": int(delay)
                })

        try:
            with open(path, 'w') as f:
                json.dump(profile, f, indent=2)
            self.status_label.setText(f"Saved to {path}")
        except Exception as e:
            QMessageBox.critical(self, "Error", f"Failed to save: {e}")

    def load_profile(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "Load Profile", "radar_profile.json", "JSON Files (*.json)"
        )
        if not path:
            return

        try:
            with open(path, 'r') as f:
                data = json.load(f)

            self.sequence.setRowCount(0)
            for i, cmd in enumerate(data.get("commands", [])):
                self.sequence.insertRow(i)
                self.sequence.setItem(i, 0, QTableWidgetItem(str(i + 1)))
                self.sequence.setItem(i, 1, QTableWidgetItem(cmd.get("command", "")))
                self.sequence.setItem(i, 2, QTableWidgetItem(cmd.get("description", "")))
                self.sequence.setItem(i, 3, QTableWidgetItem(cmd.get("expected", "")))
                self.sequence.setItem(i, 4, QTableWidgetItem(str(cmd.get("delay", 100))))
                self.sequence.setItem(i, 5, QTableWidgetItem("Pending"))
                
                send_btn = QPushButton("Send")
                send_btn.clicked.connect(lambda checked, r=i: self.send_single_command(r))
                self.sequence.setCellWidget(i, 6, send_btn)
                
            self.status_label.setText(f"Loaded from {path}")
        except Exception as e:
            QMessageBox.critical(self, "Error", f"Failed to load: {e}")

    def closeEvent(self, event):
        if self.serial_worker:
            self.serial_worker.stop()
        event.accept()


def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    app.setStyleSheet(DARK_THEME)

    w = ProfessionalRadarTool()
    w.show()

    sys.exit(app.exec_())


if __name__ == "__main__":
    main()