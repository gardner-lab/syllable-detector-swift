function convert_to_swift(fh, mat)

f = load(mat);

fprintf(fh, '// AUTOMATICALLY GENERATED SYLLABLE DETECTOR CONFIGURATION\n\n');
fprintf(fh, 'import NeuralNet\n\n');
fprintf(fh, 'struct SyllableDetectorConfig\n{\n');
fprintf(fh, '    let samplingRate: Double = %.1f\n', f.samplerate);
fprintf(fh, '    let fourierLength: Int = %d\n', f.FFT_SIZE);
fprintf(fh, '    let fourierOverlap: Int = %d\n\n', f.FFT_SIZE - (floor(f.samplerate * f.FFT_TIME_SHIFT)));

fprintf(fh, '    let freqRange: (Double, Double) = (%.1f, %.1f)\n', round((f.freq_range_ds(1) - 1.5) * f.samplerate/f.FFT_SIZE), round((f.freq_range_ds(end) - 0.5) * f.samplerate/f.FFT_SIZE));
fprintf(fh, '    let timeRange: Int = %d\n\n', f.time_window_steps);

fprintf(fh, '    let threshold: Double = %.15g\n\n', f.trigger_thresholds);

fprintf(fh, '    let net: NeuralNet\n\n');

fprintf(fh, '    init() {\n');

% build neural network

% input mapping
convert_processing_functions(fh, 'mapInputs', f.net.input);

% output mapping
convert_processing_functions(fh, 'mapOutputs', f.net.output);

% layers
layers = {};
for i = 1:length(f.net.layers)
    % add layer
	name = sprintf('layer%d', i);
	layers{i} = name;
	
	% get weights
	if 1 == i
		w = f.net.IW{i};
		if 0 < length(f.net.LW{i})
			error('Found unexpected layer weights for layer 1.');
		end
	else
		w = f.net.LW{i};
		if 0 < length(f.net.IW{i})
			error('Found unexpected input weights for layer 1.');
		end
	end
	b = f.net.b{i};
	
	% add layer
	convert_layer(fh, name, f.net.layers{i}, w, b);
end

fprintf(fh, '        net = NeuralNet(layers: [%s], inputMapping: mapInputs, outputMapping: mapOutputs)\n', strjoin(layers, ', '));
fprintf(fh, '    }\n');
fprintf(fh, '}\n');


function convert_processing_functions(fh, nm, put)
	if 1 ~= length(put.processFcns) || ~strcmp(put.processFcns{1}, 'mapminmax')
		error('Invalid processing function: %s. Expected mapminmax.', put.processFcns{1});
	end
	
	offsets = sprintf('%.15g, ', put.processSettings{1}.xoffset);
    offsets = offsets(1:end - 2); % remove final comma
	gains = sprintf('%.15g, ', put.processSettings{1}.gain);
    gains = gains(1:end - 2); % remove final comma
	
	fprintf(fh, '        let %s = MapMinMax(xOffsets: [%s], gains: [%s], yMin: %.15g))\n\n', nm, offsets, gains, put.processSettings{1}.ymin);
end

function convert_layer(fh, nm, layer, w, b)
	if ~strcmp(layer.netInputFcn, 'netsum')
        error('Invalid input function: %s. Expected netsum.', layer.netInputFcn);
	end
    
    if strcmp(layer.transferFcn, 'tansig')
        tf = 'TanSig()';
    elseif strcmp(layer.transferFcn, 'purelin')
        tf = 'PureLin()';
    else
        error('Invalid transfer function: %s.', layer.transferFcn);
    end
	
    % have to flip weights before resizing to print row by row
	weights = sprintf('%.15g, ', reshape(w', [], 1));
    weights = weights(1:end - 2); % remove final comma
	biases = sprintf('%.15g, ', b);
    biases = biases(1:end - 2); % remove final comma

	fprintf(fh, '        let %s = NeuralNetLayer(inputs: %d, weights: [%s], biases: [%s], outputs: %d, transferFunction: %s)\n\n', nm, size(w, 2), weights, biases, size(w, 1), tf);
end

end


