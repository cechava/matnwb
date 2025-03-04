classdef BoundPipe < types.untyped.datapipe.Pipe
    %BOUND Represents a Bound DataPipe which must point to a valid file.
    
    properties (SetAccess = private)
        config = types.untyped.datapipe.Configuration.empty;
        pipeProperties = {};
        stub = types.untyped.DataStub.empty;
    end
    
    properties (SetAccess = private, Dependent)
        axis;
        offset;
        dataType;
        maxSize;
        dims;
        filename;
        path;
    end
    
    methods % lifecycle
        function obj = BoundPipe(filename, path, varargin)
            import types.untyped.datapipe.Configuration;
            import types.untyped.datapipe.properties.*;
            
            obj.stub = types.untyped.DataStub(filename, path);
            
            sid = obj.stub.get_space();
            [~, h5_dims, h5_maxdims] = H5S.get_simple_extent_dims(sid);
            H5S.close(sid);
            
            current_size = fliplr(h5_dims);
            max_size = fliplr(h5_maxdims);
            h5_unlimited = H5ML.get_constant_value('H5S_UNLIMITED');
            max_size(max_size == h5_unlimited) = Inf;
            
            did = obj.getDataset();
            
            if isempty(varargin)
                obj.config = Configuration(max_size);
                axis = find(current_size < max_size);
                if ~isscalar(axis)
                    formattedAxes = sprintf('[%s]', ...
                        strjoin(cellfun(@num2str, num2cell(axis)), ', '));
                    formattedMaxSize = sprintf('[%s]', ...
                        strjoin(cellfun(@num2str, num2cell(max_size)), ', '));
                    warning('MatNWB:Untyped:DataPipe:BoundPipe:InvalidPipeShape', ...
                        ['Multiple possible axes for data pipe detected.' newline ...
                        '  Dimensions %s are all strictly smaller in size than the maximum size of %s.' newline ...
                        '  All non-appendable dimensions should fill out the maximum size of their dimension.' newline ...
                        '  Continuing with axis %s'], formattedAxes, formattedMaxSize, axis(1));
                    axis = axis(1);
                end

                obj.config.axis = axis;
                obj.config.offset = current_size(obj.config.axis);
                tid = H5D.get_type(did);
                obj.config.dataType = io.getMatType(tid);
                H5T.close(tid);
            else
                obj.config = varargin{1};
            end
            
            pid = H5D.get_create_plist(did);
            assert(Chunking.isInDcpl(pid), ['Cannot access a bound pipe if '...
                'the dataset is not chunked.']);
            obj.pipeProperties{end+1} = Chunking.fromDcpl(pid);
            
            if Compression.isInDcpl(pid)
                obj.pipeProperties{end+1} = Compression.fromDcpl(pid);
            end
            
            if Shuffle.isInDcpl(pid)
                obj.pipeProperties{end+1} = Shuffle();
            end
            
            H5P.close(pid);
            H5D.close(did);
        end
    end
    
    methods % set/get
        function val = get.axis(obj)
            val = obj.config.axis;
        end
        
        function val = get.offset(obj)
            val = obj.config.offset;
        end
        
        function val = get.dataType(obj)
            val = obj.config.dataType;
        end
        
        function val = get.maxSize(obj)
            val = obj.config.maxSize;
        end
        
        function val = get.dims(obj)
            val = obj.stub.dims;
        end
        
        function val = get.path(obj)
            val = obj.stub.path;
        end
        
        function val = get.filename(obj)
            val = obj.stub.filename;
        end
    end
    
    methods (Access = private)
        function fid = getFile(obj, access)
            if nargin < 2
                access = 'H5F_ACC_RDONLY';
            end
            fid = H5F.open(obj.filename, access, 'H5P_DEFAULT');
        end
        
        function did = getDataset(obj, access)
            if nargin < 2
                access = 'H5F_ACC_RDONLY';
            end
            fid = obj.getFile(access);
            did = H5D.open(fid, obj.path, 'H5P_DEFAULT');
            H5F.close(fid);
        end
        
        function sid = makeSelection(obj, dataSize)
            did = obj.getDataset();
            sid = H5D.get_space(did);
            H5S.select_none(sid);
            start_indices = zeros(1, length(obj.config.maxSize));
            start_indices(obj.config.axis) = obj.config.offset;
            
            h5_start = fliplr(start_indices);
            h5_stride = [];
            h5_count = fliplr(dataSize);
            h5_block = [];
            H5S.select_hyperslab(sid,...
                'H5S_SELECT_OR',...
                h5_start,...
                h5_stride,...
                h5_count,...
                h5_block);
            H5D.close(did);
        end
        
        function expandDataset(obj, data_size)
            errorId = 'NWB:Types:Untyped:DataPipe:BoundPipe:InvalidSize';
            did = obj.getDataset('H5F_ACC_RDWR');
            sid = H5D.get_space(did);
            [~, h5_dims, ~] = H5S.get_simple_extent_dims(sid);
            new_extents = data_size;
            if all(0 < h5_dims)
                current_size = fliplr(h5_dims);
                new_extents(obj.config.axis) = new_extents(obj.config.axis)...
                    + current_size(obj.config.axis);
            end
            assert(all(obj.config.maxSize >= new_extents),...
                errorId,...
                'Data size cannot exceed maximum allocated size.');
            sizes_ind = 1:length(obj.config.maxSize);
            non_axes_mask = sizes_ind ~= obj.config.axis...
                & ~isinf(obj.config.maxSize);
            assert(all(...
                obj.config.maxSize(non_axes_mask) == new_extents(non_axes_mask)),...
                errorId,...
                'Non-axis data size should match maxSize.');
            H5D.set_extent(did, fliplr(new_extents));
        end
    end
    
    %% Pipe
    methods
        function append(obj, data)
            rank = length(obj.config.maxSize);
            data_size = size(data);
            
            if 1 == rank
                data_size = max(data_size);
            elseif length(data_size) < rank
                new_coords = ones(1, rank);
                new_coords(1:length(data_size)) = data_size;
                data_size = new_coords;
            elseif length(data_size) > rank
                if ~all(data_size(rank+1:end) == 1)
                    warning('NWB:Types:Untyped:DataPipe:InvalidRank',...
                        ['Expected rank %d not expected for data of size %s.  '...
                        'Data may be lost on write.'],...
                        rank, mat2str(size(data_size)));
                end
                data_size = data_size(1:rank);
            end
            
            obj.expandDataset(data_size);
            sid = obj.makeSelection(data_size);
            
            fid = obj.getFile('H5F_ACC_RDWR');
            [mem_tid, mem_sid, data] = io.mapData2H5(fid, data, 'forceArray');
            h5_count = fliplr(data_size);
            H5S.set_extent_simple(mem_sid, rank, h5_count, h5_count);
            
            did = obj.getDataset('H5F_ACC_RDWR');
            H5D.write(did, mem_tid, mem_sid, sid, 'H5P_DEFAULT', data);
            H5S.close(mem_sid);
            if ~ischar(mem_tid)
                H5T.close(mem_tid);
            end
            H5S.close(sid);
            H5D.close(did);
            H5F.close(fid);
            
            obj.config.offset = obj.config.offset + data_size(obj.config.axis);
        end
        
        function property = getPipeProperty(obj, type)
            property = [];
            for i = 1:length(obj.pipeProperties)
                if isa(obj.pipeProperties{i}, type)
                    property = obj.pipeProperties{i};
                    return;
                end
            end
        end
        
        function setPipeProperty(~, ~)
            error('NWB:Untyped:DataPipe:BoundPipe:CannotSetPipeProperty',...
                'Bound pipes cannot override their pipe properties.');
        end
        
        function tf = hasPipeProperty(obj, name)
            for i = 1:length(obj.pipeProperties)
                if isa(obj.pipeProperties{i}, name)
                    tf = true;
                    return;
                end
            end
            tf = false;
        end
        
        function removePipeProperty(~, ~)
            error('NWB:Untyped:DataPipe:BoundPipe:CannotSetPipeProperty',...
                'Bound pipes cannot remove pipe properties.');
        end
        
        function obj = write(obj, ~, ~)
            return;
        end
        
        function data = load(obj, varargin)
            data = obj.stub.load(varargin{:});
        end
    end
end
