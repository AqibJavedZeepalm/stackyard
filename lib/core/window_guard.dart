import 'dart:ffi';
import 'dart:io';

typedef _EnumProc = Int32 Function(IntPtr hwnd, IntPtr lParam);

/// Keeps Stackyard's window usable after it runs outside tools.
///
/// A tool that opens a modal prompt owned by the foreground window disables that
/// window until the prompt closes. If the tool is killed instead (on timeout or
/// Cancel), Windows never re-enables it and the window ignores every click and
/// can't be moved. nvm-windows does exactly this. [reclaim] re-enables this
/// process's top-level window; it is a no-op when nothing is wrong.
class WindowGuard {
  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final _enumWindows = _user32
      .lookupFunction<Int32 Function(Pointer<NativeFunction<_EnumProc>>, IntPtr), int Function(Pointer<NativeFunction<_EnumProc>>, int)>('EnumWindows');
  static final _threadOf = _user32.lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
  static final _isVisible = _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindowVisible');
  static final _isEnabled = _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindowEnabled');
  static final _enable = _user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('EnableWindow');
  static final _getWindow = _user32.lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>('GetWindow');
  static final _openThread = _kernel32.lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>('OpenThread');
  static final _processOfThread = _kernel32.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('GetProcessIdOfThread');
  static final _closeHandle = _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

  static const _gwOwner = 4;
  static const _threadQueryLimitedInformation = 0x0800;

  /// Re-enables this app's visible top-level windows if something disabled them.
  static void reclaim() {
    if (!Platform.isWindows) return;
    try {
      _enumWindows(Pointer.fromFunction<_EnumProc>(_visit, 1), 0);
    } catch (_) {
      // Never let a safety net break the caller.
    }
  }

  static int _visit(int hwnd, int _) {
    if (_isVisible(hwnd) == 0 || _isEnabled(hwnd) != 0 || _getWindow(hwnd, _gwOwner) != 0) return 1;
    final thread = _openThread(_threadQueryLimitedInformation, 0, _threadOf(hwnd, nullptr));
    if (thread == 0) return 1;
    final pid = _processOfThread(thread);
    _closeHandle(thread);
    if (pid == _pid) _enable(hwnd, 1);
    return 1;
  }

  static final _pid = pid;
}
