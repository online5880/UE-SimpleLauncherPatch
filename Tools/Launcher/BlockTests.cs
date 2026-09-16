using System;
using System.IO;
using System.Text;
using System.Security.Cryptography;

static class BlockTests
{
    static void Check(bool ok) { if (!ok) throw new Exception("Block regression failed"); }
    static string Hash(byte[] bytes) {
        using (var sha = SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "");
    }
    static void Main()
    {
        string root = Path.Combine(Path.GetTempPath(), "BlockTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            int size = LauncherForm.BlockSize;
            byte[] wanted = new byte[size * 2 + 17];
            wanted[size] = 42;
            wanted[wanted.Length - 1] = 9;
            var file = new FullFileEntry { Path = "Test.pak", Size = wanted.Length, Hash = Hash(wanted) };
            string map = "$VERSION = " + file.Hash + "\n$NUM_ENTRIES = 3\n";
            for (int i = 0; i < 3; i++) {
                byte[] block = new byte[Math.Min(size, wanted.Length - i * size)];
                Buffer.BlockCopy(wanted, i * size, block, 0, block.Length);
                File.WriteAllBytes(Path.Combine(root, i + ".block"), block);
                map += i + "\t" + block.Length + "\tSHA256:" + Hash(block) + "\n";
            }
            var blocks = LauncherForm.ParseBlockMap(map, file);
            bool rejected = false;
            try { LauncherForm.ParseBlockMap(map.Replace("2\t17\t", "2\t18\t"), file); }
            catch { rejected = true; }
            Check(rejected);
            string local = Path.Combine(root, "local.pak"), partial = Path.Combine(root, "partial");
            byte[] old = (byte[])wanted.Clone(); old[size] = 1;
            File.WriteAllBytes(local, old);
            int requests = 0;
            Action<FullFileEntry, string, long> download = (b, dest, offset) => {
                requests++; File.Copy(Path.Combine(root, b.Path + ".block"), dest, true);
            };
            long bytes = LauncherForm.AssembleBlocks(local, partial, file, blocks, download, n => {});
            Check(bytes == size && requests == 1 && LauncherForm.ComputeSha256(partial) == file.Hash);
            Check(Hash(old) == LauncherForm.ComputeSha256(local));
            File.Delete(partial);
            // Simulate interruption after the first reused block, then resume.
            try { LauncherForm.AssembleBlocks(local, partial, file, blocks,
                (b, dest, offset) => { throw new IOException("interrupted"); }, n => {}); }
            catch (IOException) { }
            Check(new FileInfo(partial).Length == size);
            requests = 0;
            Check(LauncherForm.AssembleBlocks(local, partial, file, blocks, download, n => {}) == size && requests == 1);
            File.Delete(partial);
            rejected = false;
            try { LauncherForm.AssembleBlocks(local, partial, file, blocks,
                (b, dest, offset) => File.WriteAllBytes(dest, new byte[(int)b.Size]), n => {}); }
            catch { rejected = true; }
            Check(rejected && LauncherForm.ComputeSha256(local) == Hash(old));
            File.Delete(partial);
            requests = 0;
            Check(LauncherForm.AssembleBlocks(Path.Combine(root, "missing"), partial, file, blocks,
                download, n => {}) == wanted.Length && requests == 3);
            Console.WriteLine("PASS: changed block only, tail, missing install, interrupted resume, corrupt block rejection, source preserved");
        }
        finally { Directory.Delete(root, true); }
    }
}
