// Written in the D programming language.
/**
 * Widget that runs a process and streams stdout/stderr into a read-only log area.
 * Use for onboarding, setup scripts, or any command output in the UI.
 *
 * Note: Apps that cannot depend on this widget yet (e.g. before PR merge) can
 * duplicate the pattern: thread + Mutex + string[] + setTimer to drain output
 * into a LogWidget (see Syndrome onboarding.d).
 *
 * Usage:
 *   auto term = new ProcessOutputWidget("out");
 *   term.runCommand(["winget", "install", "GitHub.cli"]);
 *
 * Copyright: dlangui contributors, 2025
 * License:   Boost License 1.0
 */
module dlangui.widgets.processoutput;

import dlangui.widgets.widget;
import dlangui.widgets.controls;
import dlangui.widgets.scroll;
import dlangui.widgets.layouts;
import dlangui.widgets.editors;
import dlangui.core.types;
import std.array : join;
import std.conv : to;
import std.utf : toUTF32;
import core.thread : Thread;
import core.sync.mutex : Mutex;
import std.process : pipeProcess, wait, Redirect;
import std.stdio : readln;

/// Widget that displays streaming output from a running process.
/// Run commands with runCommand(); output appears in the log area.
class ProcessOutputWidget : VerticalLayout {
	protected LogWidget _log;
	protected Mutex _outputMutex;
	protected string[] _pendingLines;
	protected bool _processDone;
	protected ulong _timerId;
	enum POLL_INTERVAL_MS = 150;

	this(string ID = null) {
		super(ID);
		_outputMutex = new Mutex();
		layoutWidth = FILL_PARENT;
		layoutHeight = FILL_PARENT;
		_log = new LogWidget("process_log");
		_log.layoutWidth = FILL_PARENT;
		_log.layoutHeight = FILL_PARENT;
		_log.readOnly = true;
		_log.scrollLock = true;
		_log.maxLines = 2000;
		addChild(_log);
	}

	/// Clear the output area.
	void clearOutput() {
		_log.text = ""d;
	}

	/// Append a line to the output (thread-safe; also used by timer).
	void appendLine(string line) {
		if (line.length > 0)
			_log.appendText(toUTF32(line ~ "\n"));
	}

	/// Run a command and stream stdout+stderr to the log. Returns immediately; output streams in via timer.
	/// Only one command at a time; if one is already running, this does nothing.
	void runCommand(string[] args) {
		if (args.length == 0) return;
		if (_timerId != 0) return; // already running
		appendLine("$ " ~ args.join(" "));
		_processDone = false;
		_timerId = setTimer(POLL_INTERVAL_MS);
		auto argsCopy = args.dup;
		auto th = new Thread(() {
			runProcessAndStream(argsCopy);
		});
		th.start();
	}

	private void runProcessAndStream(string[] args) {
		try {
			auto proc = pipeProcess(args, Redirect.stdout | Redirect.stderr);
			for (;;) {
				auto line = proc.stdout.readln();
				if (line.length == 0) break;
				_outputMutex.lock();
				_pendingLines ~= line.idup.to!string;
				_outputMutex.unlock();
			}
			for (;;) {
				auto line = proc.stderr.readln();
				if (line.length == 0) break;
				_outputMutex.lock();
				_pendingLines ~= line.idup.to!string;
				_outputMutex.unlock();
			}
			wait(proc.pid);
		} catch (Exception e) {
			_outputMutex.lock();
			_pendingLines ~= "Error: " ~ e.msg;
			_outputMutex.unlock();
		}
		_outputMutex.lock();
		_processDone = true;
		_outputMutex.unlock();
	}

	override bool onTimer(ulong id) {
		if (id != _timerId) return false;
		_outputMutex.lock();
		foreach (line; _pendingLines)
			appendLine(line);
		_pendingLines.length = 0;
		bool done = _processDone;
		_outputMutex.unlock();
		if (done) {
			cancelTimer(_timerId);
			_timerId = 0;
			return false;
		}
		return true;
	}

	/// Access the log widget (e.g. to set maxLines).
	@property LogWidget logWidget() { return _log; }
}
