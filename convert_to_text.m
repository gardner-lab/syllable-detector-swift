function convert_to_text(fn, mat)

% open file for writing
fh = fopen(fn, 'w');

% load network definition file
f = load(mat);

fprintf(fh, '# AUTOMATICALLY GENERATED SYLLABLE DETECTOR CONFIGURATION\n');
fprintf(fh, 'samplingRate = %.1f\n', f.samplerate);
fprintf(fh, 'fourierLength = %d\n', f.FFT_SIZE);
fprintf(fh, 'fourierOverlap = %d\n', f.FFT_SIZE - (floor(f.samplerate * f.FFT_TIME_SHIFT)));

fprintf(fh, 'freqRange = %.1f, %.1f\n', round((f.freq_range_ds(1) - 1.5) * f.samplerate/f.FFT_SIZE), round((f.freq_range_ds(end) - 0.5) * f.samplerate/f.FFT_SIZE));
fprintf(fh, 'timeRange = %d\n', f.time_window_steps);

fprintf(fh, 'threshold = %.15g\n', f.trigger_thresholds);

% build neural network

% input mapping
convert_processing_functions(fh, 'mapInputs', f.net.input);

% output mapping
convert_processing_functions(fh, 'mapOutputs', f.net.output);

fprintf(fh, 'layers = %d\n', length(f.net.layers));

% layers
layers = {};
for i = 1:length(f.net.layers)
    % add layer
	name = sprintf('layer%d', i - 1);
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

% close file handle
fclose(fh);

function convert_processing_functions(fh, nm, put)
	if 1 ~= length(put.processFcns) || ~strcmp(put.processFcns{1}, 'mapminmax')
		error('Invalid processing function: %s. Expected mapminmax.', put.processFcns{1});
	end
	
	offsets = sprintf('%.15g, ', put.processSettings{1}.xoffset);
    offsets = offsets(1:end - 2); % remove final comma
	gains = sprintf('%.15g, ', put.processSettings{1}.gain);
    gains = gains(1:end - 2); % remove final comma
	
    fprintf(fh, '%s.xOffsets = %s\n', nm, offsets);
    fprintf(fh, '%s.gains = %s\n', nm, gains);
    fprintf(fh, '%s.yMin = %.15g\n', nm, put.processSettings{1}.ymin);
end

function convert_layer(fh, nm, layer, w, b)
	if ~strcmp(layer.netInputFcn, 'netsum')
        error('Invalid input function: %s. Expected netsum.', layer.netInputFcn);
	end
    
    if strcmp(layer.transferFcn, 'tansig')
        tf = 'TanSig';
    elseif strcmp(layer.transferFcn, 'purelin')
        tf = 'PureLin';
    else
        error('Invalid transfer function: %s.', layer.transferFcn);
    end
	
    % have to flip weights before resizing to print row by row
	weights = sprintf('%.15g, ', reshape(w', [], 1));
    weights = weights(1:end - 2); % remove final comma
	biases = sprintf('%.15g, ', b);
    biases = biases(1:end - 2); % remove final comma

	fprintf(fh, '%s.inputs = %d\n', nm, size(w, 2));
    fprintf(fh, '%s.outputs = %d\n', nm, size(w, 1));
    fprintf(fh, '%s.weights = %s\n', nm, weights);
    fprintf(fh, '%s.biases = %s\n', nm, biases);
    fprintf(fh, '%s.transferFunction = %s\n', nm, tf);
end

end
