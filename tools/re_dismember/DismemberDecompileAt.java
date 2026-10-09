// Decompiles DI2 exe functions at the given addresses (headless, no auto-analysis): creates the function from
// the instruction at each address if Ghidra doesn't have one yet, then writes C to <out>.
// usage: analyzeHeadless <proj> DI2 -process DeadIsland-Win64-Shipping.exe -noanalysis
//        -scriptPath tools/re -postScript DecompileAt.java <out.c> <addr> [addr ...]
// Personal-use research; nothing from here is published.
import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.listing.Function;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DismemberDecompileAt extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        PrintWriter out = new PrintWriter(new FileWriter(args[0], true));
        DecompInterface di = new DecompInterface();
        DecompileOptions opts = new DecompileOptions();
        di.setOptions(opts);
        di.toggleCCode(true);
        di.toggleSyntaxTree(false);
        di.setSimplificationStyle("decompile");
        di.openProgram(currentProgram);
        for (int i = 1; i < args.length; i++) {
            Address a = toAddr(args[i]);
            Function f = getFunctionContaining(a);
            if (f == null) {
                new DisassembleCommand(new AddressSet(a), null, true).applyTo(currentProgram, monitor);
                f = createFunction(a, null);
            }
            if (f == null) {
                out.println("// " + args[i] + ": could not create a function");
                continue;
            }
            // Disassemble every flow the function reaches so callees appear as FUN_ symbols.
            DecompileResults r = di.decompileFunction(f, 120, monitor);
            out.println("// ===== " + f.getName() + " @ " + f.getEntryPoint() + " (asked " + args[i] + ")");
            out.println(r.decompileCompleted() ? r.getDecompiledFunction().getC() : ("// failed: " + r.getErrorMessage()));
        }
        out.close();
        di.dispose();
    }
}
