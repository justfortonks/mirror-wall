namespace MirrorWall.Core;

/// <summary>A parsed RTP packet (RFC 3550). Only the fields the depacketizer needs are kept.</summary>
public sealed record RtpPacket(byte PayloadType, bool Marker, ushort SequenceNumber, uint Timestamp, uint Ssrc, byte[] Payload)
{
    public RtpPacket(bool marker, ushort sequenceNumber, uint timestamp, byte[] payload)
        : this(96, marker, sequenceNumber, timestamp, 0, payload) { }

    /// <summary>Parses a datagram. Null for anything that isn't a well-formed RTP version 2 packet.</summary>
    public static RtpPacket? Parse(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 12 || bytes[0] >> 6 != 2) return null;
        bool hasPadding = (bytes[0] & 0x20) != 0;
        bool hasExtension = (bytes[0] & 0x10) != 0;
        int csrcCount = bytes[0] & 0x0F;

        int offset = 12 + csrcCount * 4;
        if (bytes.Length < offset) return null;
        if (hasExtension)
        {
            if (bytes.Length < offset + 4) return null;
            int words = bytes[offset + 2] << 8 | bytes[offset + 3];
            offset += 4 + words * 4;
            if (bytes.Length < offset) return null;
        }

        int end = bytes.Length;
        if (hasPadding)
        {
            int padding = bytes[end - 1];
            if (padding <= 0 || padding > end - offset) return null;
            end -= padding;
        }

        return new RtpPacket(
            (byte)(bytes[1] & 0x7F),
            (bytes[1] & 0x80) != 0,
            (ushort)(bytes[2] << 8 | bytes[3]),
            (uint)(bytes[4] << 24 | bytes[5] << 16 | bytes[6] << 8 | bytes[7]),
            (uint)(bytes[8] << 24 | bytes[9] << 16 | bytes[10] << 8 | bytes[11]),
            bytes[offset..end].ToArray());
    }

    /// <summary>Serializes the packet (no CSRCs, extension or padding). Used by tests.</summary>
    public byte[] ToBytes()
    {
        var output = new byte[12 + Payload.Length];
        output[0] = 0x80;
        output[1] = (byte)((Marker ? 0x80 : 0) | (PayloadType & 0x7F));
        output[2] = (byte)(SequenceNumber >> 8);
        output[3] = (byte)SequenceNumber;
        output[4] = (byte)(Timestamp >> 24);
        output[5] = (byte)(Timestamp >> 16);
        output[6] = (byte)(Timestamp >> 8);
        output[7] = (byte)Timestamp;
        output[8] = (byte)(Ssrc >> 24);
        output[9] = (byte)(Ssrc >> 16);
        output[10] = (byte)(Ssrc >> 8);
        output[11] = (byte)Ssrc;
        Payload.CopyTo(output, 12);
        return output;
    }
}
