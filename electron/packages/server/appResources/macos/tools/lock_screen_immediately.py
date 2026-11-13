import ctypes, ctypes.util

login = ctypes.CDLL( '/System/Library/PrivateFrameworks/login.framework/login' )
login.SACLockScreenImmediate()