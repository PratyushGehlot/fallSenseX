#!/usr/bin/env python3
"""
LD6001B Radar Sensor AT Command Configuration GUI
Professional configuration tool for UART-based radar sensor
"""

import sys
import json
import serial
import serial.tools.list_ports
from PyQt5.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QComboBox, QPushButton, QLabel, QTextEdit, QGroupBox,
    QTableWidget, QTableWidgetItem, QSpinBox, QMessageBox,
    QHeaderView, QLineEdit, QSplitter, QFileDialog
)
from PyQt5.QtCore import QTimer, Qt, pyqtSignal, QThread
from PyQt5.QtGui import QTextCursor, QColor, QTextCharFormat


def process_cmd(text):
    """Process escape sequences in command text: \\n -> newline, \\r -> carriage return"""
    return text.replace('\\n', '\n').replace('\\r', '\r')


class SerialWorker(QThread):
    """Background thread for serial communication"""
    data_received = pyqtSignal(bytes, bool)
    error_occurred = pyqtSignal(str)

    def __init__(self, port, baudrate):
        super().__init__()
        self.port = port
        self.baudrate = baudrate
        self.serial = None
        self.running = False

    def run(self):
        try:
            self.serial = serial.Serial(
                self.port,
                self.baudrate,
                timeout=1,
                write_timeout=1
            )
            self.running = True
            while self.running:
                if self.serial.in_waiting:
                    data = self.serial.read(self.serial.in_waiting)
                    self.data_received.emit(data, False)
                self.msleep(50)
        except Exception as e:
            self.error_occurred.emit(str(e))

    def send_data(self, data):
        if self.serial and self.serial.is_open:
            try:
                self.serial.write(data)
                self.data_received.emit(data, True)
            except Exception as e:
                self.error_occurred.emit(str(e))

    def stop(self):
        self.running = False
        if self.serial:
            self.serial.close()
        self.quit()
        self.wait()


class RadarConfigGUI(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("LD6001B Radar Sensor Configuration Tool")
        self.resize(1200, 650)

        self.serial_worker = None
        self.current_row_for_single = 0
        self.expected_response_single = None
        self.response_received_single = False
        self.init_ui()

    def init_ui(self):
        central_widget = QWidget()
        self.setCentralWidget(central_widget)
        main_layout = QVBoxLayout(central_widget)
        main_layout.setSpacing(5)
        main_layout.setContentsMargins(10, 10, 10, 10)

        # Connection panel
        conn_group = QGroupBox("Connection")
        conn_layout = QHBoxLayout()
        conn_layout.setSpacing(10)

        conn_layout.addWidget(QLabel("COM Port:"))
        self.port_combo = QComboBox()
        self.port_combo.setMinimumWidth(120)
        conn_layout.addWidget(self.port_combo)

        self.refresh_btn = QPushButton("Refresh")
        self.refresh_btn.clicked.connect(self.refresh_ports)
        conn_layout.addWidget(self.refresh_btn)

        conn_layout.addWidget(QLabel("Baud Rate:"))
        self.baud_spin = QSpinBox()
        self.baud_spin.setRange(9600, 921600)
        self.baud_spin.setValue(115200)
        conn_layout.addWidget(self.baud_spin)

        self.connect_btn = QPushButton("Connect")
        self.connect_btn.setCheckable(True)
        self.connect_btn.clicked.connect(self.toggle_connection)
        conn_layout.addWidget(self.connect_btn)

        self.status_label = QLabel("Status: Disconnected")
        self.status_label.setStyleSheet("color: gray;")
        conn_layout.addWidget(self.status_label)

        self.seq_status_label = QLabel("")
        conn_layout.addWidget(self.seq_status_label)

        conn_layout.addStretch()
        conn_group.setLayout(conn_layout)
        main_layout.addWidget(conn_group)

        # Horizontal splitter - Commands on left, Terminal on right
        splitter = QSplitter(Qt.Horizontal)

        # Commands panel (left side)
        commands_widget = QWidget()
        commands_layout = QVBoxLayout()
        commands_layout.setSpacing(5)

        self.cmd_table = QTableWidget(0, 5)
        self.cmd_table.setHorizontalHeaderLabels(["Command", "Expected Response", "Status", "Delay (ms)", "Action"])
        self.cmd_table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        self.cmd_table.horizontalHeader().setSectionResizeMode(1, QHeaderView.Stretch)
        self.cmd_table.horizontalHeader().setSectionResizeMode(2, QHeaderView.ResizeToContents)
        self.cmd_table.horizontalHeader().setSectionResizeMode(3, QHeaderView.ResizeToContents)
        self.cmd_table.horizontalHeader().setSectionResizeMode(4, QHeaderView.ResizeToContents)
        commands_layout.addWidget(self.cmd_table)

        cmd_btn_layout = QHBoxLayout()
        self.add_cmd_btn = QPushButton("+ Add Command")
        self.add_cmd_btn.clicked.connect(self.add_command)
        cmd_btn_layout.addWidget(self.add_cmd_btn)

        self.save_cmd_btn = QPushButton("Save Commands")
        self.save_cmd_btn.clicked.connect(self.save_commands)
        cmd_btn_layout.addWidget(self.save_cmd_btn)

        self.load_cmd_btn = QPushButton("Load Commands")
        self.load_cmd_btn.clicked.connect(self.load_commands)
        cmd_btn_layout.addWidget(self.load_cmd_btn)

        self.send_seq_btn = QPushButton("Send Sequence")
        self.send_seq_btn.clicked.connect(self.send_sequence)
        self.send_seq_btn.setEnabled(False)
        cmd_btn_layout.addWidget(self.send_seq_btn)

        self.clear_cmd_btn = QPushButton("Clear All")
        self.clear_cmd_btn.clicked.connect(self.clear_commands)
        cmd_btn_layout.addWidget(self.clear_cmd_btn)

        cmd_btn_layout.addStretch()
        commands_layout.addLayout(cmd_btn_layout)
        commands_widget.setLayout(commands_layout)

        # Terminal panel (right side)
        terminal_widget = QWidget()
        terminal_layout = QVBoxLayout()
        terminal_layout.setSpacing(5)

        terminal_header = QHBoxLayout()
        terminal_header.addWidget(QLabel("Terminal Output (TX = Red, RX = Green):"))
        terminal_header.addStretch()
        self.clear_terminal_btn = QPushButton("Clear Log")
        self.clear_terminal_btn.clicked.connect(self.clear_terminal)
        terminal_header.addWidget(self.clear_terminal_btn)
        terminal_layout.addLayout(terminal_header)

        self.terminal = QTextEdit()
        self.terminal.setReadOnly(True)
        self.terminal.setStyleSheet("background-color: #1e1e1e; color: #d4d4d4; font-family: 'Consolas', 'Courier New', monospace;")
        terminal_layout.addWidget(self.terminal)

        send_layout = QHBoxLayout()
        self.manual_cmd_input = QLineEdit()
        self.manual_cmd_input.setPlaceholderText("Enter AT command (e.g., AT+START)")
        send_layout.addWidget(self.manual_cmd_input)

        self.send_manual_btn = QPushButton("Send")
        self.send_manual_btn.clicked.connect(self.send_manual_command)
        send_layout.addWidget(self.send_manual_btn)

        terminal_layout.addLayout(send_layout)
        terminal_widget.setLayout(terminal_layout)

        splitter.addWidget(commands_widget)
        splitter.addWidget(terminal_widget)
        splitter.setStretchFactor(0, 1)
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([600, 600])
        main_layout.addWidget(splitter)

    def refresh_ports(self):
        self.port_combo.clear()
        ports = serial.tools.list_ports.comports()
        for port in ports:
            self.port_combo.addItem(f"{port.device} - {port.description}")
        if not ports:
            self.port_combo.addItem("No ports found")

    def toggle_connection(self):
        if self.serial_worker and self.serial_worker.isRunning():
            self.disconnect_serial()
        else:
            self.connect_serial()

    def connect_serial(self):
        if self.port_combo.currentIndex() < 0:
            QMessageBox.warning(self, "Error", "No COM port selected")
            return

        port_text = self.port_combo.currentText()
        port = port_text.split(" - ")[0] if " - " in port_text else port_text

        try:
            self.serial_worker = SerialWorker(port, self.baud_spin.value())
            self.serial_worker.data_received.connect(self.on_data_received)
            self.serial_worker.error_occurred.connect(self.on_error)
            self.serial_worker.start()

            self.connect_btn.setText("Disconnect")
            self.connect_btn.setChecked(True)
            self.status_label.setText(f"Connected to {port}")
            self.status_label.setStyleSheet("color: green;")
            self.send_seq_btn.setEnabled(True)
            self.log_data(f"[System] Connected to {port} at {self.baud_spin.value()} baud\n", QColor(Qt.blue))
        except serial.SerialException as e:
            self.on_error(f"Cannot open port: {e}")

    def disconnect_serial(self):
        if self.serial_worker:
            self.serial_worker.stop()
            self.serial_worker = None
        self.connect_btn.setText("Connect")
        self.connect_btn.setChecked(False)
        self.status_label.setText("Status: Disconnected")
        self.status_label.setStyleSheet("color: gray;")
        self.send_seq_btn.setEnabled(False)

    def on_data_received(self, data, is_tx):
        text = data.decode('utf-8', errors='replace')
        color = QColor(Qt.red) if is_tx else QColor(Qt.green)
        self.log_data(text, color)

    def on_error(self, error_msg):
        self.connect_btn.setText("Connect")
        self.connect_btn.setChecked(False)
        self.status_label.setText(f"Error: {error_msg}")
        self.status_label.setStyleSheet("color: red;")
        self.serial_worker = None
        QMessageBox.critical(self, "Connection Error", error_msg)

    def log_data(self, text, color):
        cursor = self.terminal.textCursor()
        cursor.movePosition(QTextCursor.End)

        format = QTextCharFormat()
        format.setForeground(color)
        cursor.setCharFormat(format)
        cursor.insertText(text)

        self.terminal.setTextCursor(cursor)
        self.terminal.ensureCursorVisible()

    def add_command(self):
        row = self.cmd_table.rowCount()
        self.cmd_table.insertRow(row)

        cmd_item = QTableWidgetItem("AT+")
        self.cmd_table.setItem(row, 0, cmd_item)

        resp_item = QTableWidgetItem("OK")
        self.cmd_table.setItem(row, 1, resp_item)

        status_item = QTableWidgetItem("Pending")
        self.cmd_table.setItem(row, 2, status_item)

        delay_item = QTableWidgetItem("100")
        self.cmd_table.setItem(row, 3, delay_item)

        send_btn = QPushButton("Send")
        send_btn.clicked.connect(lambda checked, r=row: self.send_single_command(r))
        self.cmd_table.setCellWidget(row, 4, send_btn)

    def send_single_command(self, row):
        if not self.serial_worker or not self.serial_worker.isRunning():
            self.seq_status_label.setText("Error: Not connected")
            return

        cmd = self.cmd_table.item(row, 0).text() if self.cmd_table.item(row, 0) else ""
        expected = self.cmd_table.item(row, 1).text() if self.cmd_table.item(row, 1) else ""

        if cmd:
            full_cmd = process_cmd(cmd)
            self.serial_worker.send_data(full_cmd.encode())
            self.cmd_table.item(row, 2).setText("Sent")

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
            self.cmd_table.item(row, 2).setText("Failed/Timeout")
            self.seq_status_label.setText("Command failed")
        else:
            self.cmd_table.item(row, 2).setText("OK")
            self.seq_status_label.setText("Command OK")

    def clear_commands(self):
        self.cmd_table.setRowCount(0)

    def clear_terminal(self):
        self.terminal.clear()

    def send_manual_command(self):
        cmd = self.manual_cmd_input.text().strip()
        if cmd and self.serial_worker and self.serial_worker.isRunning():
            cmd = process_cmd(cmd)
            self.serial_worker.send_data(cmd.encode())
            self.manual_cmd_input.clear()

    def send_sequence(self):
        if not self.serial_worker or not self.serial_worker.isRunning():
            self.seq_status_label.setText("Error: Not connected")
            return

        commands = []
        for row in range(self.cmd_table.rowCount()):
            cmd = self.cmd_table.item(row, 0).text() if self.cmd_table.item(row, 0) else ""
            expected = self.cmd_table.item(row, 1).text() if self.cmd_table.item(row, 1) else ""
            delay = int(self.cmd_table.item(row, 3).text()) if self.cmd_table.item(row, 3) else 100
            if cmd:
                commands.append((cmd, expected, delay, row))

        if not commands:
            self.seq_status_label.setText("No commands to send")
            return

        self.send_seq_btn.setEnabled(False)
        self.command_sequence = commands
        self.send_sequence_exec(0)

    def send_sequence_exec(self, index):
        if index >= len(self.command_sequence):
            self.send_seq_btn.setEnabled(True)
            self.seq_status_label.setText("Sequence completed")
            return

        cmd, expected, delay, row = self.command_sequence[index]
        full_cmd = process_cmd(cmd)
        self.serial_worker.send_data(full_cmd.encode())
        self.cmd_table.item(row, 2).setText("Sent")

        self.current_seq_index = index
        self.expected_response = expected if expected else None
        self.response_received = False

        self.seq_timer = QTimer()
        self.seq_timer.setSingleShot(True)
        self.seq_timer.timeout.connect(lambda: self.handle_timeout())
        self.seq_timer.start(1000)

    def handle_timeout(self):
        row = self.command_sequence[self.current_seq_index][3]

        if self.expected_response and not self.response_received:
            self.cmd_table.item(row, 2).setText("Failed/Timeout")
        else:
            self.cmd_table.item(row, 2).setText("OK")

        delay = self.command_sequence[self.current_seq_index][2]
        QTimer.singleShot(delay, lambda: self.send_sequence_exec(self.current_seq_index + 1))

    def save_commands(self):
        """Save command list to JSON file"""
        if not self.serial_worker or not self.serial_worker.isRunning():
            self.seq_status_label.setText("Connect first")
            return

        path, _ = QFileDialog.getSaveFileName(
            self, "Save Commands", "radar_commands.json", "JSON Files (*.json)"
        )
        if not path:
            return

        commands = []
        for row in range(self.cmd_table.rowCount()):
            cmd = self.cmd_table.item(row, 0).text() if self.cmd_table.item(row, 0) else ""
            expected = self.cmd_table.item(row, 1).text() if self.cmd_table.item(row, 1) else ""
            delay = self.cmd_table.item(row, 3).text() if self.cmd_table.item(row, 3) else "100"
            if cmd:
                commands.append({"command": cmd, "expected": expected, "delay": int(delay)})

        try:
            with open(path, 'w') as f:
                json.dump({"commands": commands}, f, indent=2)
            self.seq_status_label.setText(f"Saved to {path}")
        except Exception as e:
            QMessageBox.critical(self, "Error", f"Failed to save: {e}")

    def load_commands(self):
        """Load command list from JSON file"""
        path, _ = QFileDialog.getOpenFileName(
            self, "Load Commands", "radar_commands.json", "JSON Files (*.json)"
        )
        if not path:
            return

        try:
            with open(path, 'r') as f:
                data = json.load(f)

            self.cmd_table.setRowCount(0)
            for cmd_data in data.get("commands", []):
                self.add_command()
                row = self.cmd_table.rowCount() - 1
                self.cmd_table.item(row, 0).setText(cmd_data.get("command", ""))
                self.cmd_table.item(row, 1).setText(cmd_data.get("expected", ""))
                self.cmd_table.item(row, 3).setText(str(cmd_data.get("delay", 100)))
            self.seq_status_label.setText(f"Loaded from {path}")
        except Exception as e:
            QMessageBox.critical(self, "Error", f"Failed to load: {e}")

    def closeEvent(self, event):
        if self.serial_worker:
            self.serial_worker.stop()
        event.accept()


if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = RadarConfigGUI()
    window.show()
    sys.exit(app.exec_())