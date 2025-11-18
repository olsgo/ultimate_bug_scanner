data class UserProfile(val email: String?)

class FakeJob {
    val isActive: Boolean = true
    fun cancel() {}
}

fun coroutineJobGuardSafe(job: FakeJob?) {
    if (job?.isActive != true) {
        println("no active job")
        return
    }
    job.cancel()
}

fun sendWelcome(profile: UserProfile?): String {
    val ensured = profile ?: return "missing profile"
    return ensured.email?.lowercase() ?: "missing email"
}

fun logToken(token: String?): Int {
    val value = token ?: run {
        println("no token, skipping")
        return 0
    }
    return value.length
}

fun maybeAvatar(url: String?): String {
    val target = url ?: throw IllegalStateException("avatar required")
    return target.substringBefore('.')
}

fun smartCastSafe(candidate: Any?): String? {
    val admin = candidate as? MutableMap<String, String> ?: return null
    return admin["level"]
}

fun elvisSafe(profile: UserProfile?): Int? {
    val alias = profile?.email ?: return null
    return alias.length
}
