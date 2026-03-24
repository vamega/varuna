#!/usr/bin/env node

import fs from 'node:fs/promises'
import path from 'node:path'
import createTorrent from 'create-torrent'

const args = parseArgs(process.argv.slice(2))
const inputPath = args.input
const outputPath = args.output
const announce = args.announce

if (inputPath == null || outputPath == null || announce == null) {
  console.error('usage: node scripts/create_torrent.mjs --input <path> --output <file.torrent> --announce <tracker-url> [--piece-length <bytes>] [--name <torrent-name>] [--private true|false]')
  process.exit(1)
}

const pieceLength = args['piece-length'] != null ? parsePositiveInt(args['piece-length'], 'piece-length') : undefined
const privateFlag = args.private != null ? parseBoolean(args.private, 'private') : undefined

const options = {
  announceList: [[announce]],
  createdBy: 'varuna dev tooling',
  name: args.name ?? path.basename(inputPath),
  pieceLength,
  private: privateFlag
}

const torrentBuffer = await new Promise((resolve, reject) => {
  createTorrent(inputPath, options, (err, torrent) => {
    if (err) {
      reject(err)
      return
    }
    resolve(torrent)
  })
})

await fs.writeFile(outputPath, torrentBuffer)
console.log(`wrote torrent: ${outputPath}`)

function parseArgs(argv) {
  const args = {}

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (!arg.startsWith('--')) {
      throw new Error(`unexpected argument: ${arg}`)
    }

    const key = arg.slice(2)
    const value = argv[index + 1]
    if (value == null || value.startsWith('--')) {
      throw new Error(`missing value for --${key}`)
    }

    args[key] = value
    index += 1
  }

  return args
}

function parsePositiveInt(value, label) {
  const parsed = Number.parseInt(value, 10)
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`invalid ${label}: ${value}`)
  }
  return parsed
}

function parseBoolean(value, label) {
  if (value === 'true') return true
  if (value === 'false') return false
  throw new Error(`invalid ${label}: ${value}`)
}
