import Foundation
import KokoroSwift
import RocaCore

enum KokoroModelPreflight {
    private static let maxHeaderBytes = 64 * 1024 * 1024

    static let requiredModelKeys: [String] = {
        var keys: [String] = []

        func add(_ key: String) {
            keys.append(key)
        }

        func add(_ prefix: String, suffixes: [String]) {
            for suffix in suffixes {
                add("\(prefix).\(suffix)")
            }
        }

        func addLSTM(_ prefix: String) {
            add(prefix, suffixes: [
                "weight_ih_l0",
                "weight_hh_l0",
                "bias_ih_l0",
                "bias_hh_l0",
                "weight_ih_l0_reverse",
                "weight_hh_l0_reverse",
                "bias_ih_l0_reverse",
                "bias_hh_l0_reverse",
            ])
        }

        func addConvWeighted(_ prefix: String, needsBias: Bool = true) {
            add("\(prefix).weight_g")
            add("\(prefix).weight_v")
            if needsBias {
                add("\(prefix).bias")
            }
        }

        func addAdainResBlk1d(_ prefix: String, needsPool: Bool, needsProjection: Bool) {
            if needsPool {
                addConvWeighted("\(prefix).pool")
            }

            addConvWeighted("\(prefix).conv1")
            addConvWeighted("\(prefix).conv2")
            add(prefix, suffixes: [
                "norm1.fc.weight",
                "norm1.fc.bias",
                "norm2.fc.weight",
                "norm2.fc.bias",
            ])

            if needsProjection {
                addConvWeighted("\(prefix).conv1x1", needsBias: false)
            }
        }

        func addAdaINResBlock1(_ prefix: String) {
            for index in 0 ..< 3 {
                addConvWeighted("\(prefix).convs1.\(index)")
                addConvWeighted("\(prefix).convs2.\(index)")
                add(prefix, suffixes: [
                    "adain1.\(index).fc.weight",
                    "adain1.\(index).fc.bias",
                    "adain2.\(index).fc.weight",
                    "adain2.\(index).fc.bias",
                    "alpha1.\(index)",
                    "alpha2.\(index)",
                ])
            }
        }

        add("bert.embeddings.word_embeddings.weight")
        add("bert.embeddings.position_embeddings.weight")
        add("bert.embeddings.token_type_embeddings.weight")
        add("bert.embeddings.LayerNorm.weight")
        add("bert.embeddings.LayerNorm.bias")
        add("bert.encoder.embedding_hidden_mapping_in.weight")
        add("bert.encoder.embedding_hidden_mapping_in.bias")

        for layerNum in 0 ..< 1 {
            for innerGroupNum in 0 ..< 1 {
                let prefix = "bert.encoder.albert_layer_groups.\(layerNum).albert_layers.\(innerGroupNum)"
                add(prefix, suffixes: [
                    "attention.query.weight",
                    "attention.query.bias",
                    "attention.key.weight",
                    "attention.key.bias",
                    "attention.value.weight",
                    "attention.value.bias",
                    "attention.dense.weight",
                    "attention.dense.bias",
                    "attention.LayerNorm.weight",
                    "attention.LayerNorm.bias",
                    "ffn.weight",
                    "ffn.bias",
                    "ffn_output.weight",
                    "ffn_output.bias",
                    "full_layer_layer_norm.weight",
                    "full_layer_layer_norm.bias",
                ])
            }
        }

        add("bert_encoder.weight")
        add("bert_encoder.bias")

        for index in 0 ..< 6 {
            let prefix = "predictor.text_encoder.lstms.\(index)"
            if index.isMultiple(of: 2) {
                addLSTM(prefix)
            } else {
                add(prefix, suffixes: ["fc.weight", "fc.bias"])
            }
        }

        addLSTM("predictor.lstm")
        add("predictor.duration_proj.linear_layer.weight")
        add("predictor.duration_proj.linear_layer.bias")
        addLSTM("predictor.shared")

        addAdainResBlk1d("predictor.F0.0", needsPool: false, needsProjection: false)
        addAdainResBlk1d("predictor.F0.1", needsPool: true, needsProjection: true)
        addAdainResBlk1d("predictor.F0.2", needsPool: false, needsProjection: false)
        addAdainResBlk1d("predictor.N.0", needsPool: false, needsProjection: false)
        addAdainResBlk1d("predictor.N.1", needsPool: true, needsProjection: true)
        addAdainResBlk1d("predictor.N.2", needsPool: false, needsProjection: false)
        add("predictor.F0_proj.weight")
        add("predictor.F0_proj.bias")
        add("predictor.N_proj.weight")
        add("predictor.N_proj.bias")

        add("text_encoder.embedding.weight")
        for index in 0 ..< 3 {
            addConvWeighted("text_encoder.cnn.\(index).0")
            add("text_encoder.cnn.\(index).1.gamma")
            add("text_encoder.cnn.\(index).1.beta")
        }
        addLSTM("text_encoder.lstm")

        addAdainResBlk1d("decoder.encode", needsPool: false, needsProjection: true)
        addAdainResBlk1d("decoder.decode.0", needsPool: false, needsProjection: true)
        addAdainResBlk1d("decoder.decode.1", needsPool: false, needsProjection: true)
        addAdainResBlk1d("decoder.decode.2", needsPool: false, needsProjection: true)
        addAdainResBlk1d("decoder.decode.3", needsPool: true, needsProjection: true)
        addConvWeighted("decoder.F0_conv")
        addConvWeighted("decoder.N_conv")
        addConvWeighted("decoder.asr_res.0")

        add("decoder.generator.m_source.l_linear.weight")
        add("decoder.generator.m_source.l_linear.bias")
        for index in 0 ..< 2 {
            addConvWeighted("decoder.generator.ups.\(index)")
            add("decoder.generator.noise_convs.\(index).weight")
            add("decoder.generator.noise_convs.\(index).bias")
            addAdaINResBlock1("decoder.generator.noise_res.\(index)")
        }
        for index in 0 ..< 6 {
            addAdaINResBlock1("decoder.generator.resblocks.\(index)")
        }
        addConvWeighted("decoder.generator.conv_post")

        return Array(Set(keys)).sorted()
    }()

    static func validateModel(at modelURL: URL) throws {
        let availableKeys = try readSafetensorsKeys(from: modelURL)
        let missing = requiredModelKeys.filter { !availableKeys.contains($0) }

        guard missing.isEmpty else {
            throw RocaError.synthesisFailed(
                incompatibilityMessage(
                    missing: missing,
                    modelURL: modelURL
                )
            )
        }
    }

    private static func readSafetensorsKeys(from modelURL: URL) throws -> Set<String> {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: modelURL)
        } catch {
            throw RocaError.synthesisFailed("Unable to open Kokoro model at \(modelURL.path): \(error.localizedDescription)")
        }
        defer {
            try? handle.close()
        }

        let lengthData = try readBytes(count: 8, from: handle, modelURL: modelURL)
        let headerLength = littleEndianUInt64(lengthData)
        guard headerLength > 0, headerLength <= UInt64(maxHeaderBytes), headerLength <= UInt64(Int.max) else {
            throw RocaError.synthesisFailed("Invalid safetensors header length in \(modelURL.path): \(headerLength)")
        }

        let headerData = try readBytes(count: Int(headerLength), from: handle, modelURL: modelURL)
        do {
            let object = try JSONSerialization.jsonObject(with: headerData)
            guard let header = object as? [String: Any] else {
                throw RocaError.synthesisFailed("Invalid safetensors header in \(modelURL.path): expected a JSON object")
            }
            return Set(header.keys.compactMap { key in
                guard key != "__metadata__" else {
                    return nil
                }
                return KokoroWeightKeyNormalizer.normalizedKey(key)
            })
        } catch let error as RocaError {
            throw error
        } catch {
            throw RocaError.synthesisFailed("Invalid safetensors header JSON in \(modelURL.path): \(error.localizedDescription)")
        }
    }

    private static func readBytes(count: Int, from handle: FileHandle, modelURL: URL) throws -> Data {
        do {
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else {
                throw RocaError.synthesisFailed("Truncated safetensors file at \(modelURL.path)")
            }
            return data
        } catch let error as RocaError {
            throw error
        } catch {
            throw RocaError.synthesisFailed("Unable to read Kokoro model at \(modelURL.path): \(error.localizedDescription)")
        }
    }

    private static func littleEndianUInt64(_ data: Data) -> UInt64 {
        data.enumerated().reduce(UInt64(0)) { value, element in
            value | (UInt64(element.element) << UInt64(element.offset * 8))
        }
    }

    private static func incompatibilityMessage(missing: [String], modelURL: URL) -> String {
        let previewLimit = 12
        let preview = missing.prefix(previewLimit).joined(separator: ", ")
        var message = "Kokoro model is incompatible with this provider build. Missing \(missing.count) required safetensors key(s) in \(modelURL.lastPathComponent): \(preview)"
        if missing.count > previewLimit {
            message += ", ..."
        }
        return message
    }
}
