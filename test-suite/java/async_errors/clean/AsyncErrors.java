import java.util.concurrent.CompletableFuture;

public class AsyncErrors {
    public static String loadUser() {
        CompletableFuture<String> future = CompletableFuture.supplyAsync(() -> "user");
        return future.handle((result, err) -> {
            if (err != null) {
                throw new IllegalStateException("failed", err);
            }
            return result;
        }).join();
    }

    public static void logChain() {
        CompletableFuture.supplyAsync(() -> "value")
            .thenApply(String::toUpperCase)
            .exceptionally(ex -> {
                System.err.println("chain failed " + ex.getMessage());
                return "fallback";
            })
            .thenAccept(System.out::println);
    }

    public static void main(String[] args) {
        loadUser();
        logChain();
    }
}
