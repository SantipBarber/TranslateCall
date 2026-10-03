func log() {
    // ruleid: no-print
    print("hello")
    // ok: no-print
    logger.info("hello")
    // ruleid: hardcoded-secret
    let apiKey = "sk_live_0123456789abcdefABCDEF"
}
