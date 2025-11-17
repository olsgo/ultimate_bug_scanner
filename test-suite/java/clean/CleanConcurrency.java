import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class CleanConcurrency {
    public void submitTasks(List<Callable<Void>> tasks) throws InterruptedException, ExecutionException {
        ExecutorService exec = Executors.newFixedThreadPool(4);
        try {
            exec.invokeAll(new ArrayList<>(tasks)).forEach(future -> {
                try {
                    future.get();
                } catch (InterruptedException | ExecutionException e) {
                    throw new RuntimeException(e);
                }
            });
        } finally {
            exec.shutdown();
        }
    }
}
