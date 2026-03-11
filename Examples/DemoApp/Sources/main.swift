import Foundation

var i = 0
while true {
    print("[\(Date())] Hello from DemoApp (stdout) #\(i)")
    fflush(stdout)
    fputs("[\(Date())] Hello from DemoApp (stderr) #\(i)\n", stderr)
    i += 1
    Thread.sleep(forTimeInterval: 2)
}
