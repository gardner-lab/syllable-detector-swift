function convert_to_text(fn, mat)

% load network definition file
f = load(mat);

% matlab uses a FFT window of 256 for anything smaller than 256
% once there is separate support for windowing and fft size, we can re-add
% this functionality
if f.fft_size < 256
    error('FFT size of %d is currently unsupported.', f.fft_size);
end

if f.fft_size ~= 2^nextpow2(f.fft_size)
    error('Only FFT sizes that are a power of two are supported.');
end

% open file for writing
fh = fopen(fn, 'w');

fprintf(fh, '# AUTOMATICALLY GENERATED SYLLABLE DETECTOR CONFIGURATION\n');
fprintf(fh, 'samplingRate = %.1f\n', f.samplerate);
fprintf(fh, 'fourierLength = %d\n', f.fft_size);
fprintf(fh, 'fourierOverlap = %d\n', f.fft_size - f.fft_time_shift);

fprintf(fh, 'freqRange = %.1f, %.1f\n', f.freq_range(1), f.freq_range_ds(end));
fprintf(fh, 'timeRange = %d\n', f.time_window_steps);

fprintf(fh, 'threshold = %.15g\n', f.trigger_thresholds);

fprintf(fh, 'scaling = %s\n', f.scaling);

% build neural network

% input mapping
convert_processing_functions(fh, 'processInputs', f.net.input);

% output mapping
convert_processing_functions(fh, 'processOutputs', f.net.output);

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
    switch length(put.processFcns)
        case 0
            % default to normalizing row (DOES NOT MATCH MATLAB, SPECIFIC FOR THIS PROJECT)
            fprintf(fh, '%s.function = normalize\n', nm);

        case 1
            if ~strcmp(put.processFcns{1}, 'mapminmax')
                error('Invalid processing function: %s. Expected mapminmax.', put.processFcns{1});
            end

            offsets = sprintf('%.15g, ', put.processSettings{1}.xoffset);
            offsets = offsets(1:end - 2); % remove final comma
            gains = sprintf('%.15g, ', put.processSettings{1}.gain);
            gains = gains(1:end - 2); % remove final comma

            fprintf(fh, '%s.function = mapminmax\n', nm);
            fprintf(fh, '%s.xOffsets = %s\n', nm, offsets);
            fprintf(fh, '%s.gains = %s\n', nm, gains);
            fprintf(fh, '%s.yMin = %.15g\n', nm, put.processSettings{1}.ymin);


        otherwise
            error('Invalid processing functions. Only one processing function is supported.');
    end
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
