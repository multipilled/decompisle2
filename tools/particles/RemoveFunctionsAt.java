// Removes the functions that start at the given addresses (undo of a ParticlesDecompileAt call made on a chunk's
// interior). usage: analyzeHeadless ... -postScript RemoveFunctionsAt.java <addr> [addr ...]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

public class RemoveFunctionsAt extends GhidraScript {
    @Override
    public void run() throws Exception {
        for (String s : getScriptArgs()) {
            Address a = toAddr(s);
            Function f = getFunctionAt(a);
            if (f != null) {
                removeFunction(f);
                println("removed " + s);
            }
        }
    }
}
