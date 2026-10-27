// Copyright 2026 Noverberrain.
// SPDX-License-Identifier: Apache-2.0

///|
pub(all) suberror ChainError {
  InvalidChainState(String)
  InvalidChainLink(file_index~ : Int32, reason~ : String)
} derive(Debug)

///|
pub extend ChainError with @debug.Debug::{to_repr}

///|
priv enum ChainPhase {
  Ready(Bytes?)
  Active
  Complete
  Failed
}

///|
/// CLI-only ordered file validation. The caller supplies each filename and
/// feeds events from a fresh BinlogFileReader; no target files are opened here.
pub struct RotationChain {
  priv mut phase : ChainPhase
  priv mut files : Int32
  priv mut next_offset : UInt64
  priv mut rotation : @moonbinlog.RotateEvent?
  priv max_event_size : UInt32
  priv names : Array[Bytes]
}

///|
pub fn RotationChain::new(
  max_event_size~ : UInt32 = 16777216,
) -> RotationChain raise ChainError {
  guard max_event_size >= 19 else {
    raise InvalidChainState("invalid event limit")
  }
  {
    phase: Ready(None),
    files: 0,
    next_offset: 4,
    rotation: None,
    max_event_size,
    names: [],
  }
}

///|
fn RotationChain::invalidate(self : RotationChain) -> Unit {
  self.phase = Failed
  self.rotation = None
}

///|
pub fn RotationChain::begin_file(
  self : RotationChain,
  basename : Bytes,
) -> Unit raise ChainError {
  errdefer self.invalidate()
  guard self.phase is Ready(expected) else {
    raise InvalidChainState("chain cannot begin a file now")
  }
  guard self.files < 128 && !basename.is_empty() else {
    raise InvalidChainState("invalid file count or empty basename")
  }
  for previous in self.names {
    guard previous != basename else {
      raise InvalidChainLink(
        file_index=self.files,
        reason="repeated basename in chain",
      )
    }
  }
  if expected is Some(expected) {
    guard expected == basename else {
      raise InvalidChainLink(
        file_index=self.files,
        reason="ROTATE target differs from next supplied basename",
      )
    }
  }
  self.files += 1
  self.names.push(basename)
  self.next_offset = 4
  self.rotation = None
  self.phase = Active
}

///|
pub fn RotationChain::feed(
  self : RotationChain,
  event : @moonbinlog.BinlogFileEvent,
) -> @moonbinlog.RotateEvent? raise {
  errdefer self.invalidate()
  guard self.phase is Active else {
    raise InvalidChainState("chain has no active file")
  }
  guard self.rotation is None else {
    raise InvalidChainLink(
      file_index=self.files - 1,
      reason="ROTATE must be the final event in a chain file",
    )
  }
  guard event.header.file_offset == self.next_offset &&
    (self.next_offset != 4 || event.header.event_type == 15) else {
    raise InvalidChainState(
      "file must start with FDE at 4 and have contiguous physical offsets",
    )
  }
  let size = event.header.event_size.to_uint64()
  guard self.next_offset <= 0xffffffffffffffffUL - size else {
    raise InvalidChainState("physical offset overflow")
  }
  if event.header.event_type == 4 {
    self.rotation = Some(
      @moonbinlog.RotateEvent::parse(
        event.format,
        event.raw,
        file_offset=event.header.file_offset,
        max_event_size=self.max_event_size,
      ),
    )
  }
  self.next_offset += size
  self.rotation
}

///|
/// Call only after the reader returns clean EOF. Intermediate files must end
/// in ROTATE to position 4; the final supplied file need not have a successor.
pub fn RotationChain::end_file(
  self : RotationChain,
  file_bytes : Int32,
  has_next~ : Bool,
) -> Unit raise ChainError {
  errdefer self.invalidate()
  guard self.phase is Active &&
    file_bytes >= 4 &&
    self.next_offset > 4 &&
    self.next_offset == file_bytes.reinterpret_as_uint().to_uint64() else {
    raise InvalidChainState("file was not consumed completely")
  }
  if has_next {
    guard self.rotation is Some(rotation) else {
      raise InvalidChainLink(
        file_index=self.files - 1,
        reason="intermediate file has no terminal ROTATE",
      )
    }
    guard rotation.position == 4 else {
      raise InvalidChainLink(
        file_index=self.files - 1,
        reason="only target position 4 is supported",
      )
    }
    self.phase = Ready(Some(rotation.next_binlog))
  } else {
    self.phase = Complete
  }
  self.rotation = None
}

///|
pub fn RotationChain::finish(self : RotationChain) -> Unit raise ChainError {
  errdefer self.invalidate()
  guard self.phase is Complete else {
    raise InvalidChainState("chain did not finish its final supplied file")
  }
}
