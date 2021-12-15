function addRawData(DynamicTable, column, data)
%ADDRAWDATA Internal method for adding data to DynamicTable given column
% name and data. Indices are determined based on data format and available
% indices.
validateattributes(column, {'char'}, {'scalartext'});


% Don't set the data until after indices are updated.
if 8 == exist('types.hdmf_common.VectorData', 'class')
    VecData = types.hdmf_common.VectorData();
else
    VecData = types.core.VectorData();
end

VecData.description = sprintf('AUTOGENERATED description for column `%s`', column);
VecData.data = [];

if isprop(DynamicTable, column)
    if isempty(DynamicTable.(column))
        DynamicTable.(column) = VecData;
    end
    VecData = DynamicTable.(column);
elseif isKey(DynamicTable.vectordata, column)
    VecData = DynamicTable.vectordata.get(column);
else
    DynamicTable.vectordata.set(column, VecData);
end

if ~isempty(VecData.data) && ...
        size(data, ndims(VecData.data)) > 1 && ...
        ~isequal(size(data),size(VecData.data))
    data = {data};
end

% grab all available indices for column.
indexChain = {column};
while true
    index = types.util.dynamictable.getIndex(DynamicTable, indexChain{end});
    if isempty(index)
        break;
    end
    indexChain{end+1} = index;
end

% find true nesting depth of column data.
depth = getNestedDataDepth(data);

for iVec = (length(indexChain)+1):depth
    indexChain{iVec} = types.util.dynamictable.addVecInd(DynamicTable, indexChain{end});
end

for iVec = (depth+1):length(indexChain)
    data = {data}; % wrap until the correct number of vector indices are satisfied.
end

nestedAdd(DynamicTable, indexChain, data);
end

function depth = getNestedDataDepth(data)
depth = 1;
subData = data;
while iscell(subData) && ~iscellstr(subData)
    depth = depth + 1;
    subData = subData{1};
end
end

function numEntries = nestedAdd(DynamicTable, indChain, data)
name = indChain{end};
if isprop(DynamicTable, name)
    Vector = DynamicTable.(name);
elseif isprop(DynamicTable, 'vectorindex') && DynamicTable.vectorindex.isKey(name)
    Vector = DynamicTable.vectorindex.get(name);
else
    Vector = DynamicTable.vectordata.get(name);
end
% figure out how many entries to be added
if isempty(Vector.data) || ...
    isequal(size(data),size(Vector.data))
    % catches when table has one entry or less
    if size(data,1) == 1
        % one-dimensional column
        maxDim = ndims(data);
    else
        maxDim = ndims(data)+1;
    end
else
    maxDim = ndims(Vector.data);
end
numEntries = size(data, maxDim);

if isa(Vector, 'types.hdmf_common.VectorIndex') || isa(Vector, 'types.core.VectorIndex')
    elems = zeros(numEntries, 1);
    for iEntry = 1:numEntries
        elems(iEntry) = nestedAdd(DynamicTable, indChain(1:(end-1)), data{iEntry});
    end
    
    raggedOffset = 0;
    if isa(Vector.data, 'types.untyped.DataPipe')
        if isa(Vector.data.internal, 'types.untyped.datapipe.BlueprintPipe')...
                && ~isempty(Vector.data.internal.data)
            raggedOffset = Vector.data.internal.data(end);
        elseif isa(Vector.data.internal, 'types.untyped.datapipe.BoundPipe')...
                && ~any(Vector.data.internal.stub.dims == 0)
            raggedOffset = Vector.data.internal.stub(end);
        end
    elseif ~isempty(Vector.data)
        raggedOffset = Vector.data(end);
    end
    
    data = double(raggedOffset) + cumsum(elems);
    if isa(Vector.data, 'types.untyped.DataPipe')
        Vector.data.append(data);
    else
        % cast to double so the correct type shrinkwrap doesn't force-clamp
        % values.
        Vector.data = cat(maxDim, double(Vector.data), data);
    end
else
    
    if ischar(data)
        data = mat2cell(data, ones(size(data, 1), 1));
    end
    
    if isa(Vector.data, 'types.untyped.DataPipe')
        Vector.data.append(data);
    else
        Vector.data = cat(maxDim, Vector.data, data);
    end
end
end