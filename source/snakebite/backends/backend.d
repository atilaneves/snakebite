module snakebite.backend;


private:


public interface Backend {
    import dmd.func: FuncDeclaration;

    public void run(FuncDeclaration fun);
}
