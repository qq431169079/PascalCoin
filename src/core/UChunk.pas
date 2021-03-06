unit UChunk;

{ Copyright (c) 2016 by Albert Molina

  Distributed under the MIT software license, see the accompanying file LICENSE
  or visit http://www.opensource.org/licenses/mit-license.php.

  This unit is a part of the PascalCoin Project, an infinitely scalable
  cryptocurrency. Find us here:
  Web: https://www.pascalcoin.org
  Source: https://github.com/PascalCoin/PascalCoin

  If you like it, consider a donation using Bitcoin:
  16K3HCZRhFUtM8GdWRcfKeaa6KsuyxZaYk

  THIS LICENSE HEADER MUST NOT BE REMOVED.
}

{$IFDEF FPC}
  {$mode delphi}
{$ENDIF}

interface

uses
  Classes, SysUtils,
  {$IFDEF FPC}
    // NOTE:
    // Due to FreePascal 3.0.4 (and earlier) bug, will not use internal "paszlib" package, use modified instead
    // Updated on PascalCoin v4.0.2
    {$IFDEF VER3_2}
      zStream, // <- Not used in current FreePascal v3.0.4 caused by a bug: https://bugs.freepascal.org/view.php?id=34422
    {$ELSE}
      paszlib_zStream,
    {$ENDIF}
  {$ELSE}
  zlib,
  {$ENDIF}
  UAccounts, ULog, UConst, UCrypto, UBaseTypes, UPCDataTypes;

type

  EPCChunk = Class(Exception);

  { TPCChunk }

  TPCChunk = Class
  private
  public
    class function SaveSafeBoxChunkFromSafeBox(SafeBoxStream, DestStream : TStream; fromBlock, toBlock : Cardinal; var errors : String) : Boolean;
    class function LoadSafeBoxFromChunk(Chunk, DestStream : TStream; var safeBoxHeader : TPCSafeBoxHeader; var errors : String) : Boolean;
  end;

  { TPCSafeboxChunks }

  TPCSafeboxChunks = Class
  private
    FChunks : Array of TStream;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function Count : Integer;
    procedure AddChunk(ASafeboxStreamChunk : TStream);
    function GetSafeboxChunk(index : Integer) : TStream;
    function GetSafeboxChunkHeader(index : Integer) : TPCSafeBoxHeader;
    function IsComplete : Boolean;
    function GetSafeboxHeader : TPCSafeBoxHeader;
  end;

implementation

{ TPCSafeboxChunks }

constructor TPCSafeboxChunks.Create;
begin
  SetLength(FChunks,0);
end;

destructor TPCSafeboxChunks.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TPCSafeboxChunks.Clear;
var i : Integer;
begin
  For i:=0 to Count-1 do begin
    FChunks[i].Free;
  end;
  SetLength(FChunks,0);
end;

function TPCSafeboxChunks.Count: Integer;
begin
  Result := Length(FChunks);
end;

procedure TPCSafeboxChunks.AddChunk(ASafeboxStreamChunk: TStream);
var LLastHeader, LsbHeader : TPCSafeBoxHeader;
begin
  If Not TPCSafeBox.LoadSafeBoxStreamHeader(ASafeboxStreamChunk,LsbHeader) then begin
    Raise EPCChunk.Create('SafeBoxStream is not a valid SafeBox to add!');
  end;
  if (Count>0) then begin
    LLastHeader := GetSafeboxChunkHeader(Count-1);
    if (LsbHeader.ContainsFirstBlock)
      or (LsbHeader.startBlock<>LLastHeader.endBlock+1)
      or (LLastHeader.ContainsLastBlock)
      or (LsbHeader.protocol<>LLastHeader.protocol)
      or (LsbHeader.blocksCount<>LLastHeader.blocksCount)
      or (Not LsbHeader.safeBoxHash.IsEqualTo( LLastHeader.safeBoxHash ))
      then begin
      raise EPCChunk.Create(Format('Cannot add %s at (%d) %s',[LsbHeader.ToString,Length(FChunks),LLastHeader.ToString]));
    end;
  end else if (Not LsbHeader.ContainsFirstBlock) then begin
    raise EPCChunk.Create(Format('Cannot add %s',[LsbHeader.ToString]));
  end;
  //
  SetLength(FChunks,Length(FChunks)+1);
  FChunks[High(FChunks)] := ASafeboxStreamChunk;
end;

function TPCSafeboxChunks.GetSafeboxChunk(index: Integer): TStream;
begin
  if (index<0) or (index>=Count) then raise EPCChunk.Create(Format('Invalid index %d of %d',[index,Length(FChunks)]));
  Result := FChunks[index];
  Result.Position := 0;
end;

function TPCSafeboxChunks.GetSafeboxChunkHeader(index: Integer): TPCSafeBoxHeader;
begin
  If Not TPCSafeBox.LoadSafeBoxStreamHeader(GetSafeboxChunk(index),Result) then begin
    Raise EPCChunk.Create(Format('Cannot capture header index %d of %d',[index,Length(FChunks)]));
  end;
end;

function TPCSafeboxChunks.IsComplete: Boolean;
var LsbHeader : TPCSafeBoxHeader;
begin
  if Count=0 then Result := False
  else begin
    LsbHeader := GetSafeboxChunkHeader(Count-1);
    Result := LsbHeader.ContainsLastBlock;
  end;
end;

function TPCSafeboxChunks.GetSafeboxHeader: TPCSafeBoxHeader;
begin
  if Not IsComplete then Raise EPCChunk.Create(Format('Chunks are not complete %d',[Length(FChunks)]));
  Result := GetSafeboxChunkHeader(Count-1);
  Result.startBlock := 0;
end;

{ TPCChunk }

class function TPCChunk.SaveSafeBoxChunkFromSafeBox(SafeBoxStream, DestStream : TStream; fromBlock, toBlock: Cardinal; var errors : String) : Boolean;
Var
  c: Cardinal;
  cs : Tcompressionstream;
  auxStream : TStream;
  iPosSize, iAux : Int64;
  initialSbPos : Int64;
  sbHeader : TPCSafeBoxHeader;
begin
  Result := false; errors := '';
  // Chunk struct:
  // - Header:
  //   - Magic value  (fixed AnsiString)
  //   - SafeBox version (2 bytes)
  //   - Uncompressed size (4 bytes)
  //   - Compressed size (4 bytes)
  // - Data:
  //   - Compressed data using ZLib
  initialSbPos :=SafeBoxStream.Position;
  Try
    If Not TPCSafeBox.LoadSafeBoxStreamHeader(SafeBoxStream,sbHeader) then begin
      errors := 'SafeBoxStream is not a valid SafeBox!';
      exit;
    end;
    If (sbHeader.startBlock>fromBlock) Or (sbHeader.endBlock<ToBlock) Or (fromBlock>toBlock) then begin
      errors := Format('Cannot save a chunk from %d to %d on a stream with %d to %d!',[fromBlock,toBlock,sbHeader.startBlock,sbHeader.endBlock]);
      exit;
    end;
    TLog.NewLog(ltDebug,ClassName,Format('Saving safebox chunk from %d to %d (current blockscount: %d)',[FromBlock,ToBlock,sbHeader.blocksCount]));

    // Header:
    TStreamOp.WriteAnsiString(DestStream,TEncoding.ASCII.GetBytes(CT_SafeBoxChunkIdentificator));
    DestStream.Write(CT_SafeBoxBankVersion,SizeOf(CT_SafeBoxBankVersion));
    //
    auxStream := TMemoryStream.Create;
    try
      SafeBoxStream.Position:=initialSbPos;
      If Not TPCSafeBox.CopySafeBoxStream(SafeBoxStream,auxStream,fromBlock,toBlock,errors) then exit;
      auxStream.Position:=0;
      // Save uncompressed size
      c := auxStream.Size;
      DestStream.Write(c,SizeOf(c));
      // Save compressed size ... later
      iPosSize := DestStream.Position;
      c := $FFFFFFFF;
      DestStream.Write(c,SizeOf(c)); // Save 4 random bytes, latter will be changed
      //
      // Zip it and add to Stream
      cs := Tcompressionstream.create(clFastest,DestStream);
        // Note: Previously was using clDefault, but found a bug for FreePascal 3.0.4
        // https://bugs.freepascal.org/view.php?id=34422
        // On 2018-10-15 changed clDefault to clFastest
      try
        cs.CopyFrom(auxStream,auxStream.Size); // compressing
      finally
        cs.Free;
      end;
    finally
      auxStream.Free;
    end;
    //
    iAux := DestStream.Position;
    c := DestStream.Position - iPosSize - 4; // Save data size
    DestStream.Position:=iPosSize;
    DestStream.Write(c,SizeOf(c));
    DestStream.Position := iAux; // Back to last position
    Result := True; errors := '';
  finally
    SafeBoxStream.Position:=initialSbPos;
  end;
end;

class function TPCChunk.LoadSafeBoxFromChunk(Chunk, DestStream: TStream; var safeBoxHeader : TPCSafeBoxHeader; var errors: String): Boolean;
var raw : TRawBytes;
  w : Word;
  cUncompressed, cCompressed : Cardinal;
  ds : Tdecompressionstream;
  dbuff : Array[1..2048] of byte;
  r : Integer;
  destInitialPos, auxPos : Int64;
begin
  Result := false;
  safeBoxHeader := CT_PCSafeBoxHeader_NUL;
  // Header:
  errors := 'Invalid stream header';
  TStreamOp.ReadAnsiString(Chunk,raw);
  If (Not TBaseType.Equals(raw,TEncoding.ASCII.GetBytes(CT_SafeBoxChunkIdentificator))) then begin
    exit;
  end;
  Chunk.Read(w,sizeof(w));
  if (w<>CT_SafeBoxBankVersion) then begin
    errors := errors + ' Invalid version '+IntToStr(w);
    exit;
  end;
  // Size
  Chunk.Read(cUncompressed,SizeOf(cUncompressed)); // Uncompressed size
  Chunk.Read(cCompressed,SizeOf(cCompressed)); // Compressed size
  if (Chunk.Size - Chunk.Position < cCompressed) then begin
    errors := Format('Not enough LZip bytes Stream.size:%d Stream.position:%d (avail %d) LZipSize:%d',[Chunk.Size,Chunk.Position,Chunk.Size - Chunk.Position,cCompressed]);
    exit;
  end;
  //
  destInitialPos:=DestStream.Position;
  ds := Tdecompressionstream.create(Chunk);
  try
    repeat
      r := ds.read(dbuff,SizeOf(dbuff));
      if (r>0) then begin
        DestStream.Write(dbuff,r);
      end;
    until r < SizeOf(dbuff);
    //auxStream.CopyFrom(Stream,cCompressed);
  finally
    ds.Free;
  end;
  If (DestStream.Size-destInitialPos)<>cUncompressed then begin
    errors := Format('Uncompressed size:%d <> saved:%d',[(DestStream.Size-destInitialPos),cUncompressed]);
    exit;
  end;

  auxPos := DestStream.Position;
  DestStream.Position:=destInitialPos;
  If Not TPCSafeBox.LoadSafeBoxStreamHeader(DestStream,safeBoxHeader) then begin
    errors:= 'Invalid extracted stream!';
    exit;
  end;
  DestStream.Position:=auxPos;
  Result := true;
end;

end.

