module snakebite.reported_after_heredoc;
enum s = q"EOS
import " and dmd.
EOS";
import dmd.typesem: mutableOf;
