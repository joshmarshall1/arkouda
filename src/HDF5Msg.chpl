module HDF5Msg {
    use CTypes;
    use FileSystem;
    use HDF5;
    use IO;
    use List;
    use PrivateDist;
    use Reflection;
    use Set;
    use ArkoudaTimeCompat as Time;
    use AryUtil;
    use ArkoudaRegexCompat;

    use CommAggregation;
    use FileIO;
    use FileSystem;
    use GenSymIO;
    use Logging;
    use Message;
    use MultiTypeSymbolTable;
    use MultiTypeSymEntry;
    use NumPyDType;
    use ServerConfig;
    use ServerErrors;
    use ServerErrorStrings;
    use SegmentedString;
    use Sort;

    use ArkoudaMapCompat;
    use ArkoudaListCompat;
    use ArkoudaStringBytesCompat;


    private config const logLevel = ServerConfig.logLevel;
    private config const logChannel = ServerConfig.logChannel;
    const h5Logger = new Logger(logLevel, logChannel);

    const ARKOUDA_HDF5_FILE_METADATA_GROUP = "/_arkouda_metadata";
    const ARKOUDA_HDF5_ARKOUDA_VERSION_KEY = "arkouda_version"; // see ServerConfig.arkoudaVersion
    type ARKOUDA_HDF5_ARKOUDA_VERSION_TYPE = c_string;
    const ARKOUDA_HDF5_FILE_VERSION_KEY = "file_version";
    const ARKOUDA_HDF5_FILE_VERSION_VAL = 2.0:real(32);
    type ARKOUDA_HDF5_FILE_VERSION_TYPE = real(32);
    config const NA_VALUE_KEY = "NA_Value";
    config const SEGMENTED_OFFSET_NAME = "segments";
    config const SEGMENTED_VALUE_NAME = "values";
    config const CATEGORIES_NAME = "categories";
    config const CODES_NAME = "codes";
    config const NACODES_NAME = "NA_Codes";
    config const PERMUTATION_NAME = "permutation";
    config const SEGMENTS_NAME = "segments";
    config const UKI_NAME = "unique_key_idx";

    config const TRUNCATE: int = 0;
    config const APPEND: int = 1;

    config const SINGLE_FILE: int = 0;
    config const MULTI_FILE: int = 1;

    require "c_helpers/help_h5ls.h", "c_helpers/help_h5ls.c";
    private extern proc c_get_HDF5_obj_type(loc_id:C_HDF5.hid_t, name:c_string, obj_type:c_ptr(C_HDF5.H5O_type_t)):C_HDF5.herr_t;
    private extern proc c_strlen(s:c_ptr(c_char)):c_size_t;
    private extern proc c_incrementCounter(data:c_void_ptr);
    private extern proc c_append_HDF5_fieldname(data:c_void_ptr, name:c_string);

    /*
     * Returns the HDF5 data type corresponding to the dataset, which delegates
     * to getHDF5Type for all datatypes supported by Chapel. For datatypes that
     * are not supported by Chapel, getDataType encapsulates logic to retrieve
     * the HDF5 data type.
     */
    proc getDataType(A) : C_HDF5.hid_t {
        var dType : C_HDF5.hid_t;
            
        if A.eltType == bool {
            return C_HDF5.H5T_NATIVE_HBOOL;
        } else {
            return getHDF5Type(A.eltType);
        }
    }

    /*
        Returns the C_HDF5.hid_t corresponding to the provided Chapel type
    */
    proc getDataType(type t) : C_HDF5.hid_t {
        if t == bool {
            return C_HDF5.H5T_NATIVE_HBOOL;
        }
        else {
            return getHDF5Type(t);
        }
    }

    /*
        Validates that the provided write mode is APPEND or TRUNCATE
        mode: int

        If mode is not 1 (Append) or 0 (Truncate) error
    */
    proc validateWriteMode(mode: int) throws {
        if (mode != APPEND && mode != TRUNCATE) {
            throw getErrorWithContext(
                           msg="Unknown write mode %i found.".format(mode),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
        }
    }

    /*
        Prepare the file for writing data to single file
    */
    proc prepFiles(filename: string, mode: int): string throws {
        // validate the write mode
        validateWriteMode(mode);

        var prefix: string;
        var extension: string;
        (prefix,extension) = getFileMetadata(filename);

        const f = "%s%s".format(prefix, extension);
        var matchingFilenames = glob("%s*%s".format(prefix, extension));
        
        var fileExists: bool = matchingFilenames.size > 0;
        if (mode == TRUNCATE || (mode == APPEND && !fileExists)) {
            if (mode == TRUNCATE && fileExists){
                remove(f);
            }

            h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                                             "Creating or truncating file");

            // create the file
            var file_id: C_HDF5.hid_t = C_HDF5.H5Fcreate(f.c_str(), C_HDF5.H5F_ACC_TRUNC, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
            defer { // Close file upon exiting scope
                C_HDF5.H5Fclose(file_id);
            }

            if file_id < 0 { // Negative file_id means error
                throw getErrorWithContext(msg="The file %s cannot be created".format(f),
                                            lineNumber=getLineNumber(), 
                                            routineName=getRoutineName(), 
                                            moduleName=getModuleName(), 
                                            errorClass='FileNotFoundError');
            }
            
            // Create the attribute space
            var attrSpaceId: C_HDF5.hid_t = C_HDF5.H5Screate(C_HDF5.H5S_SCALAR);
            var attr_id: C_HDF5.hid_t;
            // Create the File_Type. This will be important when merging with other read/write functionality.
            attr_id = C_HDF5.H5Acreate2(file_id, "File_Format".c_str(), getHDF5Type(int), attrSpaceId, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
            var ft: int = SINGLE_FILE;
            C_HDF5.H5Awrite(attr_id, getHDF5Type(int), c_ptrTo(ft));
            C_HDF5.H5Aclose(attr_id);

        }
        return f;
    }

    /*
        Prepare the files required to write files distributed across locales
        A is the entry to be written.
    */
    proc prepFiles(filename: string, mode: int, A): [] string throws {
        // validate the write mode
        validateWriteMode(mode);

        var prefix: string;
        var extension: string;
        (prefix,extension) = getFileMetadata(filename);

        var targetSize = A.targetLocales().size;
        var filenames: [0..#targetSize] string;
        forall i in 0..#targetSize {
            filenames[i] = generateFilename(prefix, extension, i);
        }
        fioLogger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                "generateFilenames targetLocales.size %i, filenames.size %i".format(targetSize, filenames.size));

        var matchingFilenames = glob("%s_LOCALE*%s".format(prefix, extension));
        var filesExist: bool = matchingFilenames.size > 0;

        if (mode == TRUNCATE || (mode == APPEND && !filesExist)) {
            coforall loc in A.targetLocales() do on loc {
                var file_id: C_HDF5.hid_t;
                var fn = filenames[loc.id].localize();
                var existList = glob(fn);
                if mode == TRUNCATE && existList.size == 1 {
                    remove(fn);
                }
                h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                                             "Creating or truncating file");

                file_id = C_HDF5.H5Fcreate(fn.c_str(), C_HDF5.H5F_ACC_TRUNC,
                                                            C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
                defer { // Close file upon exiting scope
                    C_HDF5.H5Fclose(file_id);
                }

                if file_id < 0 { // Negative file_id means error
                  throw getErrorWithContext(
                                    msg="The file %s cannot be created".format(fn),
                                    lineNumber=getLineNumber(), 
                                    routineName=getRoutineName(), 
                                    moduleName=getModuleName(), 
                                    errorClass='FileNotFoundError');
              }
              // Create the attribute space
                var attrSpaceId: C_HDF5.hid_t = C_HDF5.H5Screate(C_HDF5.H5S_SCALAR);
                var attr_id: C_HDF5.hid_t;
                // Create the File_Type. This will be important when merging with other read/write functionality.
                attr_id = C_HDF5.H5Acreate2(file_id, "File_Format".c_str(), getHDF5Type(int), attrSpaceId, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
                var ft: int = MULTI_FILE;
                C_HDF5.H5Awrite(attr_id, getHDF5Type(int), c_ptrTo(ft));
                C_HDF5.H5Aclose(attr_id);
            }
        }
        else if mode == APPEND {
            if filenames.size != matchingFilenames.size {
                throw getErrorWithContext(
                           msg="Cannot append when the number of existing filenames does not match the expected.",
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
            }
        }
        return filenames;
    }

    /*
        Validate that the dataset name provided does not already exist
    */
    proc validateDataset(file_id: C_HDF5.hid_t, filename: string, dset_name: string, overwrite: bool) throws {
        // validate that the dataset does not already exist
        var dset_exists: int = C_HDF5.H5Lexists(file_id, dset_name.localize().c_str(), C_HDF5.H5P_DEFAULT);
        if (dset_exists > 0 && overwrite) {
            var del_status: int = C_HDF5.H5Ldelete(file_id, dset_name.localize().c_str(), C_HDF5.H5P_DEFAULT);
            if del_status < 0 {
                throw getErrorWithContext(
                           msg="Unable to overwrite dataset named %s in %s.".format(dset_name, filename),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="RuntimeError");
            }
        }
        else if dset_exists > 0 {
            throw getErrorWithContext(
                           msg=" Dataset named %s already exists in %s. If you would like to overwrite the group please use update_hdf.".format(dset_name, filename),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
        }
        else if dset_exists < 0 {
            throw getErrorWithContext(
                           msg="Failure validating the status of dataset named %s.".format(dset_name),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
        }
    }

    /*
        Validate that the group does not already exist.
        If it does not exist, it is created.
    */
    proc validateGroup(file_id: C_HDF5.hid_t, filename: string, group: string, overwrite: bool) throws {
        var group_exists: int = C_HDF5.H5Lexists(file_id, group.localize().c_str(), C_HDF5.H5P_DEFAULT);
        if (group_exists > 0 && overwrite) {
            var del_status: int = C_HDF5.H5Ldelete(file_id, group.localize().c_str(), C_HDF5.H5P_DEFAULT);
            if del_status < 0 {
                throw getErrorWithContext(
                           msg="Unable to overwrite group named %s in %s.".format(group, filename),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="RuntimeError");
            }
            // recreate the group to write overwrite data too
            var groupId: C_HDF5.hid_t = C_HDF5.H5Gcreate2(file_id, "/%s".format(group).c_str(),
                                    C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
            C_HDF5.H5Gclose(groupId);
        }
        else if group_exists > 0 {
            throw getErrorWithContext(
                           msg="A group named %s already exists in %s. If you would like to overwrite the group please use update_hdf.".format(group, filename),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="RuntimeError");
        }
        else if group_exists < 0 {
            throw getErrorWithContext(
                           msg="Failure validating the status of group named %s.".format(group),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="RuntimeError");
        }
        else {
            // create the group
            var groupId: C_HDF5.hid_t = C_HDF5.H5Gcreate2(file_id, "/%s".format(group).c_str(),
                                    C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
            C_HDF5.H5Gclose(groupId);
        }
    }

    /*
        Write Arkouda metadata attributes to the provided object. 
        
        file_id: C_HDF5.hid_t
            ID of the file the attributes are to be written to. This should be the id of a group or dataset

        objName: string
            Name of the group or dataset the attributes are being written to.

        objType: string
            The type of the object stored in the parent. ArrayView, pdarray, or strings

        dtype: C_HDF5.hid_t
            id of the C_HDF5 datatype of the data contained in the object. Used to check for boolean datasets
    */
    proc writeArkoudaMetaData(file_id: C_HDF5.hid_t, objName: string, objType: string, dtype: C_HDF5.hid_t) throws {
        var obj_id: C_HDF5.hid_t = C_HDF5.H5Oopen(file_id, objName.localize().c_str(), C_HDF5.H5P_DEFAULT);

        // Create the attribute space
        var attrSpaceId: C_HDF5.hid_t = C_HDF5.H5Screate(C_HDF5.H5S_SCALAR);
        var attr_id: C_HDF5.hid_t;

         // Create the objectType. This will be important when merging with other read/write functionality.
        attr_id = C_HDF5.H5Acreate2(obj_id, "ObjType".c_str(), getHDF5Type(int), attrSpaceId, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
        var t: ObjType = objType.toUpper(): ObjType;
        var t_int: int = t: int;
        C_HDF5.H5Awrite(attr_id, getHDF5Type(int), c_ptrTo(t_int));
        C_HDF5.H5Aclose(attr_id);

        // write attribute for boolean
        if dtype == C_HDF5.H5T_NATIVE_HBOOL {
            attr_id = C_HDF5.H5Acreate2(obj_id, "isBool".c_str(), getHDF5Type(int), attrSpaceId, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
            var isBool: int = 1;
            C_HDF5.H5Awrite(attr_id, getHDF5Type(int), c_ptrTo(isBool));
            C_HDF5.H5Aclose(attr_id);
        }

        var attrFileVersionType = getHDF5Type(ARKOUDA_HDF5_FILE_VERSION_TYPE);
        var attrId = C_HDF5.H5Acreate2(obj_id,
                          ARKOUDA_HDF5_FILE_VERSION_KEY.c_str(),
                          attrFileVersionType,
                          attrSpaceId,
                          C_HDF5.H5P_DEFAULT,
                          C_HDF5.H5P_DEFAULT);
        
        // H5Awrite requires a pointer and we have a const, so we need a variable ref we can turn into a pointer
        var fileVersion = ARKOUDA_HDF5_FILE_VERSION_VAL;
        C_HDF5.H5Awrite(attrId, attrFileVersionType, c_ptrTo(fileVersion));
        C_HDF5.H5Aclose(attrId);

        var attrStringType = C_HDF5.H5Tcopy(C_HDF5.H5T_C_S1): C_HDF5.hid_t;
        C_HDF5.H5Tset_size(attrStringType, arkoudaVersion.size:uint(64) + 1); // ensure space for NULL terminator
        C_HDF5.H5Tset_strpad(attrStringType, C_HDF5.H5T_STR_NULLTERM);
        
        attrId = C_HDF5.H5Acreate2(obj_id,
                            ARKOUDA_HDF5_ARKOUDA_VERSION_KEY.c_str(),
                            attrStringType,
                            attrSpaceId,
                            C_HDF5.H5P_DEFAULT,
                            C_HDF5.H5P_DEFAULT);

        // For the value, we need to build a ptr to a char[]; c_string doesn't work because it is a const char*        
        var akVersion = c_calloc(c_char, arkoudaVersion.size+1);
        for (c, i) in zip(arkoudaVersion.codepoints(), 0..<arkoudaVersion.size) {
            akVersion[i] = c:c_char;
        }
        akVersion[arkoudaVersion.size] = 0:c_char; // ensure NULL termination

        C_HDF5.H5Awrite(attrId, attrStringType, akVersion);
        C_HDF5.H5Aclose(attrId);

        // release ArkoudaVersion HDF5 resources
        c_free(akVersion);
        C_HDF5.H5Sclose(attrSpaceId);
        C_HDF5.H5Tclose(attrStringType);
        C_HDF5.H5Oclose(obj_id);
    }

    proc writeGroupByMetaData(file_id: C_HDF5.hid_t, objName: string, objType: string, num_keys: int) throws {
        var obj_id: C_HDF5.hid_t = C_HDF5.H5Oopen(file_id, objName.localize().c_str(), C_HDF5.H5P_DEFAULT);

        // Create the attribute space
        var attrSpaceId: C_HDF5.hid_t = C_HDF5.H5Screate(C_HDF5.H5S_SCALAR);
        var attr_id: C_HDF5.hid_t;

        // Create the objectType. This will be important when merging with other read/write functionality.
        attr_id = C_HDF5.H5Acreate2(obj_id, "ObjType".c_str(), getHDF5Type(int), attrSpaceId, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
        var t: ObjType = objType.toUpper(): ObjType;
        var t_int: int = t: int;
        C_HDF5.H5Awrite(attr_id, getHDF5Type(int), c_ptrTo(t_int));
        C_HDF5.H5Aclose(attr_id);

        attr_id = C_HDF5.H5Acreate2(obj_id, "NumKeys".c_str(), getHDF5Type(int), attrSpaceId, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
        var nk = num_keys; // need to generate c_ptrTo
        C_HDF5.H5Awrite(attr_id, getHDF5Type(int), c_ptrTo(nk));
        C_HDF5.H5Aclose(attr_id);

        var attrFileVersionType = getHDF5Type(ARKOUDA_HDF5_FILE_VERSION_TYPE);
        var attrId = C_HDF5.H5Acreate2(obj_id,
                          ARKOUDA_HDF5_FILE_VERSION_KEY.c_str(),
                          attrFileVersionType,
                          attrSpaceId,
                          C_HDF5.H5P_DEFAULT,
                          C_HDF5.H5P_DEFAULT);
        
        // H5Awrite requires a pointer and we have a const, so we need a variable ref we can turn into a pointer
        var fileVersion = ARKOUDA_HDF5_FILE_VERSION_VAL;
        C_HDF5.H5Awrite(attrId, attrFileVersionType, c_ptrTo(fileVersion));
        C_HDF5.H5Aclose(attrId);

        var attrStringType = C_HDF5.H5Tcopy(C_HDF5.H5T_C_S1): C_HDF5.hid_t;
        C_HDF5.H5Tset_size(attrStringType, arkoudaVersion.size:uint(64) + 1); // ensure space for NULL terminator
        C_HDF5.H5Tset_strpad(attrStringType, C_HDF5.H5T_STR_NULLTERM);
        
        attrId = C_HDF5.H5Acreate2(obj_id,
                            ARKOUDA_HDF5_ARKOUDA_VERSION_KEY.c_str(),
                            attrStringType,
                            attrSpaceId,
                            C_HDF5.H5P_DEFAULT,
                            C_HDF5.H5P_DEFAULT);

        // For the value, we need to build a ptr to a char[]; c_string doesn't work because it is a const char*        
        var akVersion = c_calloc(c_char, arkoudaVersion.size+1);
        for (c, i) in zip(arkoudaVersion.codepoints(), 0..<arkoudaVersion.size) {
            akVersion[i] = c:c_char;
        }
        akVersion[arkoudaVersion.size] = 0:c_char; // ensure NULL termination

        C_HDF5.H5Awrite(attrId, attrStringType, akVersion);
        C_HDF5.H5Aclose(attrId);

        // release ArkoudaVersion HDF5 resources
        c_free(akVersion);
        C_HDF5.H5Sclose(attrSpaceId);
        C_HDF5.H5Tclose(attrStringType);
        C_HDF5.H5Oclose(obj_id);
    }

    /*
        Writes Attributes specific to a multidimensional array.
            - objType = ArrayView
            - Rank: int - rank of the dataset
            - Shape: [] int - stores the shape of object.
        Calls to writeArkoudaMetaData to write the arkouda metadata
    */
    proc writeArrayViewAttrs(file_id: C_HDF5.hid_t, dset_name: string, objType: string, shape: SymEntry, dtype:C_HDF5.hid_t) throws {
        h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                        "Writing ArrayView Attrs");
        //open the created dset so we can add attributes.
        var dset_id: C_HDF5.hid_t = C_HDF5.H5Dopen(file_id, dset_name.localize().c_str(), C_HDF5.H5P_DEFAULT);

        // Create the attribute space
        var attrSpaceId: C_HDF5.hid_t = C_HDF5.H5Screate(C_HDF5.H5S_SCALAR);
        var attr_id: C_HDF5.hid_t;

        // Store the rank of the dataset. Required to read so that shape can be built
        attr_id = C_HDF5.H5Acreate2(dset_id, "Rank".c_str(), getHDF5Type(int), attrSpaceId, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
        var s = shape.size; // needed to localize in the event that shape is not local.
        C_HDF5.H5Awrite(attr_id, getHDF5Type(int), c_ptrTo(s));
        C_HDF5.H5Aclose(attr_id);

        C_HDF5.H5Sclose(attrSpaceId);
        attrSpaceId= C_HDF5.H5Screate(C_HDF5.H5S_SIMPLE);
        var adim: [0..#1] C_HDF5.hsize_t = shape.size:C_HDF5.hsize_t;
        C_HDF5.H5Sset_extent_simple(attrSpaceId, 1, c_ptrTo(adim), c_ptrTo(adim));

        attr_id = C_HDF5.H5Acreate2(dset_id, "Shape".c_str(), getHDF5Type(shape.a.eltType), attrSpaceId, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
        var localShape = new lowLevelLocalizingSlice(shape.a, 0..#shape.size);
        C_HDF5.H5Awrite(attr_id, getHDF5Type(shape.a.eltType), localShape.ptr);
        C_HDF5.H5Aclose(attr_id);

        // close the space and the dataset
        C_HDF5.H5Sclose(attrSpaceId);
        C_HDF5.H5Dclose(dset_id);

        // add arkouda meta data attributes
        writeArkoudaMetaData(file_id, dset_name, objType, dtype);
    }

    /*
        writes 1D array to dataset in single file
    */
    proc writeLocalDset(file_id: C_HDF5.hid_t, dset_name: string, A, dimension: int, type t) throws{
        h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                        "Writing dataset, %s".format(dset_name));
        // Convert the Chapel dtype to HDF5
        var dtype_id: C_HDF5.hid_t = getDataType(t);

        // always store multidimensional arrays as flattened array
        var dims = dimension:C_HDF5.hsize_t;
        C_HDF5.H5LTmake_dataset(file_id, dset_name.c_str(), 1:c_int, dims, dtype_id, A);
    }

    /*
        write 1d array to dataset in files distributed over locales
    */
    proc writeDistDset(filenames: [] string, dset_name: string, objType: string, overwrite: bool, A, st: borrowed SymTab, shape_name: string = "") throws {
        coforall (loc, idx) in zip(A.targetLocales(), filenames.domain) do on loc {
            const localeFilename = filenames[idx];
            h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                        "%s exists? %t".format(localeFilename, exists(localeFilename)));

            var file_id = C_HDF5.H5Fopen(localeFilename.c_str(), C_HDF5.H5F_ACC_RDWR, C_HDF5.H5P_DEFAULT);
            defer { // Close the file on scope exit
                C_HDF5.H5Fclose(file_id);
            }

            // validate that the dataset does not already exist
            validateDataset(file_id, localeFilename, dset_name, overwrite);

            const locDom = A.localSubdomain();
            var dims: [0..#1] C_HDF5.hsize_t;
            dims[0] = locDom.size: C_HDF5.hsize_t;

            use C_HDF5.HDF5_WAR;

            var dType: C_HDF5.hid_t = getDataType(A);

            /*
            * Depending upon the datatype, write the local slice out to the top-level
            * or nested, named group within the hdf5 file corresponding to the locale.
            */
            if locDom.size <= 0 {
                H5LTmake_dataset_WAR(file_id, dset_name.localize().c_str(), 1, c_ptrTo(dims), dType, nil);
            } else {
                H5LTmake_dataset_WAR(file_id, dset_name.localize().c_str(), 1, c_ptrTo(dims), dType, c_ptrTo(A.localSlice(locDom)));
            }

            // write the appropriate attributes
            if shape_name != "" {
                // write attributes for multi-dim array
                var shape_sym: borrowed GenSymEntry = getGenericTypedArrayEntry(shape_name, st);
                var shape = toSymEntry(shape_sym, int);
                writeArrayViewAttrs(file_id, dset_name, objType, shape, dType);
            }
            else {
                // write attributes for arkouda meta info otherwise
                writeArkoudaMetaData(file_id, dset_name, objType, dType);
            }
        }
    }

    /*
        Process and write an Arkouda ArrayView to HDF5.
    */
    proc arrayView_tohdfMsg(msgArgs: MessageArgs, st: borrowed SymTab) throws {
        // access integer representation of APPEND/TRUNCATE
        var mode: int = msgArgs.get("write_mode").getIntValue();

        var filename: string = msgArgs.getValueOf("filename");
        var entry = st.lookup(msgArgs.getValueOf("values"));
        var file_format = msgArgs.get("file_format").getIntValue();
        var overwrite: bool = if msgArgs.contains("overwrite")
                                then msgArgs.get("overwrite").getBoolValue()
                                else false;

        const entryDtype = msgArgs.get("values").getDType();

        var dset_name = msgArgs.getValueOf("dset");
        const objType = msgArgs.getValueOf("objType");

        select file_format {
            when SINGLE_FILE {
                var f = prepFiles(filename, mode);
                var file_id = C_HDF5.H5Fopen(f.c_str(), C_HDF5.H5F_ACC_RDWR, C_HDF5.H5P_DEFAULT);
                if file_id < 0 { // HF5open returns negative value on failure
                    C_HDF5.H5Fclose(file_id);
                    var errorMsg = "Failure accessing file %s.".format(f);
                    throw getErrorWithContext(
                           msg=errorMsg,
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="FileNotFoundError");
                }

                // validate that the dataset does not already exist
                validateDataset(file_id, f, dset_name, overwrite);

                var shape_sym: borrowed GenSymEntry = getGenericTypedArrayEntry(msgArgs.getValueOf("shape"), st);
                var shape = toSymEntry(shape_sym, int);
                var dims: int = * reduce shape.a;

                var dtype: C_HDF5.hid_t;
                
                select entryDtype {
                    when DType.Int64 {
                        var flat = toSymEntry(toGenSymEntry(entry), int);
                        var localFlat: [0..#flat.size] int = flat.a;
                        
                        writeLocalDset(file_id, dset_name, c_ptrTo(localFlat), dims, int);
                        dtype = getHDF5Type(int);
                    }
                    when DType.UInt64 {
                        var flat = toSymEntry(toGenSymEntry(entry), uint);
                        var localFlat: [0..#flat.size] uint = flat.a;
                        
                        writeLocalDset(file_id, dset_name, c_ptrTo(localFlat), dims, uint);
                        dtype = getHDF5Type(uint);
                    }
                    when DType.Float64 {
                        var flat = toSymEntry(toGenSymEntry(entry), real);
                        var localFlat: [0..#flat.size] real = flat.a;
                        
                        writeLocalDset(file_id, dset_name, c_ptrTo(localFlat), dims, real);
                        dtype = getHDF5Type(real);
                    }
                    when DType.Bool {
                        var flat = toSymEntry(toGenSymEntry(entry), bool);
                        var localFlat: [0..#flat.size] bool = flat.a;
                        
                        writeLocalDset(file_id, dset_name, c_ptrTo(localFlat), dims, bool);
                        dtype = C_HDF5.H5T_NATIVE_HBOOL;
                    }
                    otherwise {
                        var errorMsg = unrecognizedTypeError("arrayView_tohdfMsg", dtype2str(entryDtype));
                        throw getErrorWithContext(
                           msg=errorMsg,
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="TypeError");
                    }
                }
                // write attributes for multi-dim array
                writeArrayViewAttrs(file_id, dset_name, objType, shape, dtype);
                C_HDF5.H5Fclose(file_id);
            }
            when MULTI_FILE {
                select entryDtype {
                    when DType.Int64 {
                        var e = toSymEntry(toGenSymEntry(entry), int);
                        var filenames = prepFiles(filename, mode, e.a);
                        writeDistDset(filenames, dset_name, objType, overwrite, e.a, st, msgArgs.getValueOf("shape"));
                    }
                    when DType.UInt64 {
                        var e = toSymEntry(toGenSymEntry(entry), uint);
                        var filenames = prepFiles(filename, mode, e.a);
                        writeDistDset(filenames, dset_name, objType, overwrite, e.a, st, msgArgs.getValueOf("shape"));
                    }
                    when DType.Float64 {
                        var e = toSymEntry(toGenSymEntry(entry), real);
                        var filenames = prepFiles(filename, mode, e.a);
                        writeDistDset(filenames, dset_name, objType, overwrite, e.a, st, msgArgs.getValueOf("shape"));
                    }
                    when DType.Bool {
                        var e = toSymEntry(toGenSymEntry(entry), bool);
                        var filenames = prepFiles(filename, mode, e.a);
                        writeDistDset(filenames, dset_name, objType, overwrite, e.a, st, msgArgs.getValueOf("shape"));
                    }
                    otherwise {
                        var errorMsg = unrecognizedTypeError("multiDimArray_tohdfMsg", dtype2str(entryDtype));
                        throw getErrorWithContext(
                           msg=errorMsg,
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="TypeError");
                    }
                }
            }
            otherwise {
                throw getErrorWithContext(
                           msg="Unknown file format. Expecting 0 (single file) or 1 (file per locale). Found %i".format(file_format),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
            }
        }
    }

    /*
        Process and write an Arkouda pdarray to HDF5.
    */
    proc pdarray_tohdfMsg(msgArgs: MessageArgs, st: borrowed SymTab) throws {
        var mode: int = msgArgs.get("write_mode").getIntValue();

        var filename: string = msgArgs.getValueOf("filename");
        var entry = st.lookup(msgArgs.getValueOf("values"));
        var file_format = msgArgs.get("file_format").getIntValue();
        var overwrite: bool = if msgArgs.contains("overwrite")
                                then msgArgs.get("overwrite").getBoolValue()
                                else false;

        const entryDtype = msgArgs.get("values").getDType();

        var dset_name = msgArgs.getValueOf("dset");
        const objType = msgArgs.getValueOf("objType");
        var dtype: C_HDF5.hid_t;

        select file_format {
            when SINGLE_FILE {
                var f = prepFiles(filename, mode);
                var file_id = C_HDF5.H5Fopen(f.c_str(), C_HDF5.H5F_ACC_RDWR, C_HDF5.H5P_DEFAULT);
                if file_id < 0 { // HF5open returns negative value on failure
                    C_HDF5.H5Fclose(file_id);
                    var errorMsg = "Failure accessing file %s.".format(f);
                    throw getErrorWithContext(
                           msg=errorMsg,
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="FileNotFoundError");
                }

                // validate that the dataset does not already exist
                validateDataset(file_id, f, dset_name, overwrite);

                select entryDtype {
                    when DType.Int64 {
                        var flat = toSymEntry(toGenSymEntry(entry), int);
                        var localFlat: [0..#flat.size] int = flat.a;

                        writeLocalDset(file_id, dset_name, c_ptrTo(localFlat), flat.size, int);
                        dtype = getHDF5Type(int);
                    }
                    when DType.UInt64 {
                        var flat = toSymEntry(toGenSymEntry(entry), uint);
                        var localFlat: [0..#flat.size] uint = flat.a;

                        writeLocalDset(file_id, dset_name, c_ptrTo(localFlat), flat.size, uint);
                        dtype = getHDF5Type(uint);
                    }
                    when DType.Float64 {
                        var flat = toSymEntry(toGenSymEntry(entry), real);
                        var localFlat: [0..#flat.size] real = flat.a;

                        writeLocalDset(file_id, dset_name, c_ptrTo(localFlat), flat.size, real);
                        dtype = getHDF5Type(real);
                    }
                    when DType.Bool {
                        var flat = toSymEntry(toGenSymEntry(entry), bool);
                        var localFlat: [0..#flat.size] bool = flat.a;

                        writeLocalDset(file_id, dset_name, c_ptrTo(localFlat), flat.size, bool);
                        dtype = C_HDF5.H5T_NATIVE_HBOOL;
                    }
                    otherwise {
                        var errorMsg = unrecognizedTypeError("pdarray_tohdfmsg", dtype2str(entryDtype));
                        throw getErrorWithContext(
                           msg=errorMsg,
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="TypeError");
                    }
                }
                // write attributes for arkouda meta info
                writeArkoudaMetaData(file_id, dset_name, objType, dtype);
                C_HDF5.H5Fclose(file_id);
            }
            when MULTI_FILE {
                select entryDtype {
                    when DType.Int64 {
                        var e = toSymEntry(toGenSymEntry(entry), int);
                        var filenames = prepFiles(filename, mode, e.a);
                        writeDistDset(filenames, dset_name, objType, overwrite, e.a, st);
                    }
                    when DType.UInt64 {
                        var e = toSymEntry(toGenSymEntry(entry), uint);
                        var filenames = prepFiles(filename, mode, e.a);
                        writeDistDset(filenames, dset_name, objType, overwrite, e.a, st);
                    }
                    when DType.Float64 {
                        var e = toSymEntry(toGenSymEntry(entry), real);
                        var filenames = prepFiles(filename, mode, e.a);
                        writeDistDset(filenames, dset_name, objType, overwrite, e.a, st);
                    }
                    when DType.Bool {
                        var e = toSymEntry(toGenSymEntry(entry), bool);
                        var filenames = prepFiles(filename, mode, e.a);
                        writeDistDset(filenames, dset_name, objType, overwrite, e.a, st);
                    }
                    otherwise {
                        var errorMsg = unrecognizedTypeError("pdarray_tohdfmsg", dtype2str(entryDtype));
                        throw getErrorWithContext(
                           msg=errorMsg,
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="TypeError");
                    }
                }
            }
            otherwise {
                throw getErrorWithContext(
                           msg="Unknown file format. Expecting 0 (single file) or 1 (file per locale). Found %i".format(file_format),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
            }
        }
    }

    /**
     * Writes empty "Strings" components to the designated parent group in the HDF5 file
     * :arg fileId: HDF5 file id
     * :type fileId: int
     *
     * :arg group: parent dataset / group name for values and segments
     * :type group: string
     *
     * :arg writeOffsets: boolean switch for whether or not to write offsets/segements to file
     * :type writeOffsets: bool
     */
    private proc writeNilSegmentedGroupToHdf(fileId: int, group: string, writeOffsets: bool, ctype) throws {
        var dset_id: C_HDF5.hid_t;
        var zero = 0: uint(64);

        // create empty values dataset
        C_HDF5.H5LTmake_dataset_WAR(fileId, "/%s/%s".format(group, SEGMENTED_VALUE_NAME).c_str(), 1,
                c_ptrTo(zero), ctype, nil);

        dset_id = C_HDF5.H5Dopen(fileId, "/%s/%s".format(group, SEGMENTED_VALUE_NAME).c_str(), C_HDF5.H5P_DEFAULT);

        // Create the attribute space
        var attrSpaceId: C_HDF5.hid_t = C_HDF5.H5Screate(C_HDF5.H5S_SCALAR);
        var attr_id: C_HDF5.hid_t;

        // Create the objectType. This will be important when merging with other read/write functionality.
        attr_id = C_HDF5.H5Acreate2(dset_id, "ObjType".c_str(), getHDF5Type(int), attrSpaceId, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
        var val_t: ObjType = ObjType.PDARRAY;
        var val_t_int: int = val_t: int;
        C_HDF5.H5Awrite(attr_id, getHDF5Type(int), c_ptrTo(val_t_int));
        C_HDF5.H5Aclose(attr_id);
        C_HDF5.H5Sclose(attrSpaceId);
        C_HDF5.H5Dclose(dset_id);

        if (writeOffsets) {
            // create empty segments dataset
            C_HDF5.H5LTmake_dataset_WAR(fileId, "/%s/%s".format(group, SEGMENTED_OFFSET_NAME).c_str(), 1,
                c_ptrTo(zero), getHDF5Type(int), nil);

            dset_id = C_HDF5.H5Dopen(fileId, "/%s/%s".format(group, SEGMENTED_OFFSET_NAME).c_str(), C_HDF5.H5P_DEFAULT);

            attrSpaceId = C_HDF5.H5Screate(C_HDF5.H5S_SCALAR);
            attr_id = C_HDF5.H5Acreate2(dset_id, "ObjType".c_str(), getHDF5Type(int), attrSpaceId, C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
            var seg_t: ObjType = ObjType.PDARRAY;
            var seg_t_int: int = seg_t: int;
            C_HDF5.H5Awrite(attr_id, getHDF5Type(int), c_ptrTo(seg_t_int));
            C_HDF5.H5Aclose(attr_id);
            C_HDF5.H5Sclose(attrSpaceId);
            C_HDF5.H5Dclose(dset_id);
        }
    }

    /**
     * Writes the given Stings component array to HDF5 within a group.
     * :arg fileId: HDF5 file id
     * :type fileId: int
     *
     * :arg group: parent dataset / group name to write designated component
     * :type group: string
     *
     * :arg component: name of the component to write, should be either values or segments
     * :type component: string
     *
     * :arg items: the array containing the data to be written for te specified Strings array component
     * :type items: [] ?etype
     */
    private proc writeSegmentedComponentToHdf(fileId: int, group: string, component: string, items: [] ?etype) throws {
        var numItems = items.size: uint(64);
        C_HDF5.H5LTmake_dataset_WAR(fileId, "/%s/%s".format(group, component).c_str(), 1,
                c_ptrTo(numItems), getDataType(etype), c_ptrTo(items));

        writeArkoudaMetaData(fileId, "%s/%s".format(group, component), "pdarray", getDataType(etype));
    }

    /*
        Process and write an Arkouda Strings (SegmentedString) object to HDF5.
    */
    proc strings_tohdfMsg(msgArgs: MessageArgs, st: borrowed SymTab) throws {
        use C_HDF5.HDF5_WAR;
        var mode: int = msgArgs.get("write_mode").getIntValue();

        var filename: string = msgArgs.getValueOf("filename");
        var file_format = msgArgs.get("file_format").getIntValue();
        var group = msgArgs.getValueOf("dset");
        var writeOffsets = msgArgs.get("save_offsets").getBoolValue();
        var overwrite: bool = if msgArgs.contains("overwrite")
                                then msgArgs.get("overwrite").getBoolValue()
                                else false;

        var entry:SegStringSymEntry = toSegStringSymEntry(st.lookup(msgArgs.getValueOf("values")));
        var segString = new SegString("", entry);

        const objType = msgArgs.getValueOf("objType");

        select file_format {
            when SINGLE_FILE {
                var f = prepFiles(filename, mode);
                var file_id = C_HDF5.H5Fopen(f.c_str(), C_HDF5.H5F_ACC_RDWR, C_HDF5.H5P_DEFAULT);
                if file_id < 0 { // HF5open returns negative value on failure
                    C_HDF5.H5Fclose(file_id);
                    var errorMsg = "Failure accessing file %s.".format(f);
                    throw getErrorWithContext(
                           msg=errorMsg,
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="FileNotFoundError");
                }

                // create the group
                validateGroup(file_id, f, group, overwrite);

                writeSegmentedLocalDset(file_id, group, segString.values, segString.offsets, writeOffsets, uint(8));
                writeArkoudaMetaData(file_id, group, objType, getHDF5Type(uint(8)));
                C_HDF5.H5Fclose(file_id);
            }
            when MULTI_FILE {
                var valEntry = segString.values;
                var segEntry = segString.offsets;
                var filenames = prepFiles(filename, mode, segEntry.a);
                writeSegmentedDistDset(filenames, group, objType, overwrite, valEntry.a, segEntry.a, st, uint(8));
            }
            otherwise {
                throw getErrorWithContext(
                           msg="Unknown file format. Expecting 0 (single file) or 1 (file per locale). Found %i".format(file_format),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
            }
        }
    }

    proc writeSegmentedLocalDset(file_id: C_HDF5.hid_t, group: string, vals, segs, write_offsets: bool, type t) throws {
        h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                            "Writing group, %s".format(group));

        var dtype_id: C_HDF5.hid_t = getDataType(t);
        var localVals: [0..#vals.size] t = vals.a;
        var vd = vals.size:C_HDF5.hsize_t;
        C_HDF5.H5LTmake_dataset(file_id, "%s/%s".format(group, SEGMENTED_VALUE_NAME).c_str(), 1:c_int, vd, dtype_id, c_ptrTo(localVals));
        writeArkoudaMetaData(file_id, "%s/%s".format(group, SEGMENTED_VALUE_NAME), "pdarray", dtype_id);

        if write_offsets {
            var localSegs: [0..#segs.size] int = segs.a;
            var sd = segs.size:C_HDF5.hsize_t;
            C_HDF5.H5LTmake_dataset(file_id, "%s/%s".format(group, SEGMENTED_OFFSET_NAME).c_str(), 1:c_int, sd, getDataType(int), c_ptrTo(localSegs));
            writeArkoudaMetaData(file_id, "%s/%s".format(group, SEGMENTED_OFFSET_NAME), "pdarray", getDataType(int));
        }
    }

    proc writeSegmentedDistDset(filenames: [] string, group: string, objType: string, overwrite: bool, values, segments, st: borrowed SymTab, type t) throws {
        const lastSegIdx = segments.domain.high;
        const lastValIdx = values.domain.high;
        coforall (loc, idx) in zip(segments.targetLocales(), filenames.domain) do on loc {
            const localeFilename = filenames[idx];
            h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                        "%s exists? %t".format(localeFilename, exists(localeFilename)));

            var file_id = C_HDF5.H5Fopen(localeFilename.c_str(), C_HDF5.H5F_ACC_RDWR, C_HDF5.H5P_DEFAULT);
            defer { // Close the file on scope exit
                C_HDF5.H5Fclose(file_id);
            }

            // create the group
            validateGroup(file_id, localeFilename, group, overwrite);

            const locDom = segments.localSubdomain();
            var dims: [0..#1] C_HDF5.hsize_t;
            dims[0] = locDom.size: C_HDF5.hsize_t;

            if (locDom.isEmpty() || locDom.size <= 0) {
                h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                    "write1DDistStringsAggregators: locale.id %i has empty locDom.size %i, will get empty dataset."
                    .format(loc.id, locDom.size));
                writeNilSegmentedGroupToHdf(file_id, group, true, getDataType(t));
                // write attributes for arkouda meta info
                writeArkoudaMetaData(file_id, group, objType, getDataType(t));
            } else {
                // write the segments
                var localSegs = segments[locDom];
                var startValIdx = localSegs[locDom.low];
                var endValIdx = if (lastSegIdx == locDom.high) then lastValIdx else segments[locDom.high + 1] - 1;
                var valIdxRange = startValIdx..endValIdx;

                var localVals: [valIdxRange] t;

                forall (localVal, valIdx) in zip(localVals, valIdxRange) with (var agg = newSrcAggregator(t)) {
                    // Copy the remote value at index position valIdx to our local array
                    agg.copy(localVal, values[valIdx]); // in SrcAgg, the Right Hand Side is REMOTE
                }

                writeSegmentedComponentToHdf(file_id, group, SEGMENTED_VALUE_NAME, localVals);
                localSegs = localSegs - startValIdx;
                writeSegmentedComponentToHdf(file_id, group, SEGMENTED_OFFSET_NAME, localSegs);

                writeArkoudaMetaData(file_id, group, objType, getDataType(t));
            }
        }
    }

    proc segarray_tohdfMsg(msgArgs: MessageArgs, st: borrowed SymTab) throws {
        use C_HDF5.HDF5_WAR;
        var mode: int = msgArgs.get("write_mode").getIntValue();
        var overwrite: bool = if msgArgs.contains("overwrite")
                                then msgArgs.get("overwrite").getBoolValue()
                                else false;

        var filename: string = msgArgs.getValueOf("filename");
        var file_format = msgArgs.get("file_format").getIntValue();
        var group = msgArgs.getValueOf("dset");
        var val_dType = str2dtype(msgArgs.getValueOf("dtype"));
        const objType = msgArgs.getValueOf("objType");

        // segments is always int64
        var segments = toSymEntry(toGenSymEntry(st.lookup(msgArgs.getValueOf("segments"))), int);

        select file_format {
            when SINGLE_FILE {
                var f = prepFiles(filename, mode);
                var file_id = C_HDF5.H5Fopen(f.c_str(), C_HDF5.H5F_ACC_RDWR, C_HDF5.H5P_DEFAULT);
                if file_id < 0 { // HF5open returns negative value on failure
                    C_HDF5.H5Fclose(file_id);
                    var errorMsg = "Failure accessing file %s.".format(f);
                    throw getErrorWithContext(
                           msg=errorMsg,
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="FileNotFoundError");
                }

                // create the group
                validateGroup(file_id, f, group, overwrite);
                var dtype: C_HDF5.hid_t;

                select val_dType {
                    when (DType.Int64) {
                        var values = toSymEntry(toGenSymEntry(st.lookup(msgArgs.getValueOf("values"))), int);

                        //localize values and write dataset
                        writeSegmentedLocalDset(file_id, group, values, segments, true, int);
                        dtype = getDataType(int);
                    } when (DType.UInt64) {
                        var values = toSymEntry(toGenSymEntry(st.lookup(msgArgs.getValueOf("values"))), uint);

                         //localize values and write dataset
                        writeSegmentedLocalDset(file_id, group, values, segments, true, uint);
                        dtype = getDataType(uint);
                    } when (DType.Float64) {
                        var values = toSymEntry(toGenSymEntry(st.lookup(msgArgs.getValueOf("values"))), real);

                         //localize values and write dataset
                        writeSegmentedLocalDset(file_id, group, values, segments, true, real);
                        dtype = getDataType(real);
                    } when (DType.Bool) {
                        var values = toSymEntry(toGenSymEntry(st.lookup(msgArgs.getValueOf("values"))), bool);

                         //localize values and write dataset
                        writeSegmentedLocalDset(file_id, group, values, segments, true, bool);
                        dtype = getDataType(bool);
                    }
                    otherwise {
                        throw getErrorWithContext(
                           msg="Unsupported SegArray DType %s".format(dtype2str(val_dType)),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
                    }
                }
                
                writeArkoudaMetaData(file_id, group, objType, dtype);
                C_HDF5.H5Fclose(file_id);
            }
            when MULTI_FILE {
                var filenames = prepFiles(filename, mode, segments.a);
                select val_dType {
                    when DType.Int64 {
                        var values = toSymEntry(toGenSymEntry(st.lookup(msgArgs.getValueOf("values"))), int);
                        writeSegmentedDistDset(filenames, group, objType, overwrite, values.a, segments.a, st, int);
                    }
                    when DType.UInt64 {
                        var values = toSymEntry(toGenSymEntry(st.lookup(msgArgs.getValueOf("values"))), uint);
                        writeSegmentedDistDset(filenames, group, objType, overwrite, values.a, segments.a, st, uint);
                    }
                    when DType.Float64 {
                        var values = toSymEntry(toGenSymEntry(st.lookup(msgArgs.getValueOf("values"))), real);
                        writeSegmentedDistDset(filenames, group, objType, overwrite, values.a, segments.a, st, real);
                    }
                    when DType.Bool {
                        var values = toSymEntry(toGenSymEntry(st.lookup(msgArgs.getValueOf("values"))), bool);
                        writeSegmentedDistDset(filenames, group, objType, overwrite, values.a, segments.a, st, bool);
                    }
                    otherwise {
                        throw getErrorWithContext(
                           msg="Unsupported SegArray DType %s".format(dtype2str(val_dType)),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
                    }
                }
            }
            otherwise {
                throw getErrorWithContext(
                           msg="Unknown file format. Expecting 0 (single file) or 1 (file per locale). Found %i".format(file_format),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
            }
        }
    }

    proc writeLocalCategoricalRequiredData(file_id: C_HDF5.hid_t, f: string, group: string, codes, categories, naCodes, overwrite: bool) throws {
        // localize codes and write dataset
        var localCodes: [0..#codes.size] int = codes.a;
        writeLocalDset(file_id, "/%s/%s".format(group, CODES_NAME), c_ptrTo(localCodes), codes.size, int);

        // ensure that the container for categories exists
        validateGroup(file_id, f, "%s/%s".format(group, CATEGORIES_NAME), overwrite);


        //localize categories values and write dataset
        writeSegmentedLocalDset(file_id, "/%s/%s".format(group, CATEGORIES_NAME), categories.values, categories.offsets, true, uint(8));

        // localize _akNAcode and write to dset
        var localNACodes: [0..#naCodes.size] int = naCodes.a;
        writeLocalDset(file_id, "/%s/%s".format(group, NACODES_NAME), c_ptrTo(localNACodes), naCodes.size, int);
    }

    proc writeLocalCategoricalOptionalData(file_id: C_HDF5.hid_t, group: string, permutation: string, segments: string, st: borrowed SymTab) throws {
        var perm_entry = st.lookup(permutation);
        var perm = toSymEntry(toGenSymEntry(perm_entry), int);

        // localize permutation and write dataset
        var localPerm: [0..#perm.size] int = perm.a;
        writeLocalDset(file_id, "/%s/%s".format(group, PERMUTATION_NAME), c_ptrTo(localPerm), perm.size, int);

        var segment_entry = st.lookup(segments);
        var segs = toSymEntry(toGenSymEntry(segment_entry), int);

        // localize segments and write dataset
        var localSegs: [0..#segs.size] int = segs.a;
        writeLocalDset(file_id, "/%s/%s".format(group, SEGMENTS_NAME), c_ptrTo(localSegs), segs.size, int);
    }

    proc categorical_tohdfMsg(msgArgs: borrowed MessageArgs, st: borrowed SymTab) throws {
        use C_HDF5.HDF5_WAR;
        var mode: int = msgArgs.get("write_mode").getIntValue();

        var filename: string = msgArgs.getValueOf("filename");
        var file_format = msgArgs.get("file_format").getIntValue();
        var group = msgArgs.getValueOf("dset");
        const objType = msgArgs.getValueOf("objType"); // needed for metadata

        var overwrite: bool = if msgArgs.contains("overwrite")
                                then msgArgs.get("overwrite").getBoolValue()
                                else false;

        // access entries - types are currently always the same for each
        var codes_entry = st.lookup(msgArgs.getValueOf("codes"));
        var codes = toSymEntry(toGenSymEntry(codes_entry), int);
        var cat_entry:SegStringSymEntry = toSegStringSymEntry(st.lookup(msgArgs.getValueOf("categories")));
        var cats = new SegString("", cat_entry);
        var naCodes_entry = st.lookup(msgArgs.getValueOf("NA_codes"));
        var naCodes = toSymEntry(toGenSymEntry(naCodes_entry), int);
        var perm_seg_exist: bool = false;
        if msgArgs.contains("permutation") && msgArgs.contains("segments") {
            perm_seg_exist = true;
        }
        
        select file_format {
            when SINGLE_FILE {
                var f = prepFiles(filename, mode);
                var file_id = C_HDF5.H5Fopen(f.c_str(), C_HDF5.H5F_ACC_RDWR, C_HDF5.H5P_DEFAULT);
                if file_id < 0 { // HF5open returns negative value on failure
                    C_HDF5.H5Fclose(file_id);
                    var errorMsg = "Failure accessing file %s.".format(f);
                    throw getErrorWithContext(
                           msg=errorMsg,
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="FileNotFoundError");
                }

                // ensure that container for categorical exists
                validateGroup(file_id, f, group, overwrite);

                writeLocalCategoricalRequiredData(file_id, f, group, codes, cats, naCodes, overwrite);

                if perm_seg_exist {
                    writeLocalCategoricalOptionalData(file_id, group, msgArgs.getValueOf("permutation"), msgArgs.getValueOf("segments"), st);
                }

                writeArkoudaMetaData(file_id, group, objType, getHDF5Type(uint(8))); 
                C_HDF5.H5Fclose(file_id);
            }
            when MULTI_FILE {
                var filenames = prepFiles(filename, mode, codes.a);

                // need to add the group to all files
                coforall (loc, idx) in zip(codes.a.targetLocales(), filenames.domain) do on loc {
                    const localeFilename = filenames[idx];
                    h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                "%s exists? %t".format(localeFilename, exists(localeFilename)));

                    var file_id = C_HDF5.H5Fopen(localeFilename.c_str(), C_HDF5.H5F_ACC_RDWR, C_HDF5.H5P_DEFAULT);
                    defer { // Close the file on scope exit
                        C_HDF5.H5Fclose(file_id);
                    }

                    // create the group and generate metadata
                    validateGroup(file_id, localeFilename, group, overwrite);
                    writeArkoudaMetaData(file_id, group, objType, getHDF5Type(uint(8))); 
                }

                // write codes
                writeDistDset(filenames, "/%s/%s".format(group, CODES_NAME), "pdarray", overwrite, codes.a, st);

                // write categories
                writeSegmentedDistDset(filenames, "/%s/%s".format(group, CATEGORIES_NAME), "strings", overwrite, cats.values.a, cats.offsets.a, st, uint(8));

                // write NA Codes
                writeDistDset(filenames, "/%s/%s".format(group, NACODES_NAME), "pdarray", overwrite, naCodes.a, st);

                // writes perms and segs if they exist
                if perm_seg_exist {
                    var perm_entry = st.lookup(msgArgs.getValueOf("permutation"));
                    var perm = toSymEntry(toGenSymEntry(perm_entry), int);
                    var segment_entry = st.lookup(msgArgs.getValueOf("segments"));
                    var segs = toSymEntry(toGenSymEntry(segment_entry), int);
                    writeDistDset(filenames, "/%s/%s".format(group, PERMUTATION_NAME), "pdarray", overwrite, perm.a, st);
                    writeDistDset(filenames, "/%s/%s".format(group, SEGMENTS_NAME), "pdarray", overwrite, segs.a, st);
                }
            }
            otherwise {
                throw getErrorWithContext(
                           msg="Unknown file format. Expecting 0 (single file) or 1 (file per locale). Found %i".format(file_format),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
            }
        }
    }

    proc groupby_tohdfMsg(msgArgs: borrowed MessageArgs, st: borrowed SymTab) throws {
        use C_HDF5.HDF5_WAR;
        var mode: int = msgArgs.get("write_mode").getIntValue();

        var filename: string = msgArgs.getValueOf("filename");
        var file_format = msgArgs.get("file_format").getIntValue();
        var overwrite: bool = if msgArgs.contains("overwrite")
                                then msgArgs.get("overwrite").getBoolValue()
                                else false; 

        var group = msgArgs.getValueOf("dset"); // name of the group containing components
        const objType = msgArgs.getValueOf("objType").toUpper(): ObjType; // needed to write metadata

        // access the permutation and segments pdarrays because these are always int
        var seg_entry = st.lookup(msgArgs.getValueOf("segments"));
        var segments = toSymEntry(toGenSymEntry(seg_entry), int);
        var perm_entry = st.lookup(msgArgs.getValueOf("permutation"));
        var perm = toSymEntry(toGenSymEntry(perm_entry), int);
        var uki_entry = st.lookup(msgArgs.getValueOf("unique_key_idx"));
        var uki = toSymEntry(toGenSymEntry(uki_entry), int);

        // access groupby key information
        var num_keys = msgArgs.get("num_keys").getIntValue();
        var key_names = msgArgs.get("key_names").getList(num_keys);
        var key_objTypes = msgArgs.get("key_objTypes").getList(num_keys);
        var key_dtypes = msgArgs.get("key_dtypes").getList(num_keys);

        select file_format {
            when SINGLE_FILE {
                var f = prepFiles(filename, mode);
                var file_id = C_HDF5.H5Fopen(f.c_str(), C_HDF5.H5F_ACC_RDWR, C_HDF5.H5P_DEFAULT);
                if file_id < 0 { // HF5open returns negative value on failure
                    C_HDF5.H5Fclose(file_id);
                    var errorMsg = "Failure accessing file %s.".format(f);
                    throw getErrorWithContext(
                           msg=errorMsg,
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="FileNotFoundError");
                }

                // create/overwrite the group
                validateGroup(file_id, f, group, overwrite);

                var localseg: [0..#segments.size] int = segments.a;
                writeLocalDset(file_id, "/%s/%s".format(group, SEGMENTS_NAME), c_ptrTo(localseg), segments.size, int);
                writeArkoudaMetaData(file_id, "/%s/%s".format(group, SEGMENTS_NAME), "pdarray", getDataType(int));

                var localperm: [0..#perm.size] int = perm.a;
                writeLocalDset(file_id, "/%s/%s".format(group, PERMUTATION_NAME), c_ptrTo(localperm), perm.size, int);
                writeArkoudaMetaData(file_id, "/%s/%s".format(group, PERMUTATION_NAME), "pdarray", getDataType(int));

                var localuki: [0..#uki.size] int = uki.a;
                writeLocalDset(file_id, "/%s/%s".format(group, UKI_NAME), c_ptrTo(localuki), uki.size, int);
                writeArkoudaMetaData(file_id, "/%s/%s".format(group, UKI_NAME), "pdarray", getDataType(int));

                // loop keys and create/write dataset for each
                for (i, name, ot, dt) in zip(0..#num_keys, key_names, key_objTypes, key_dtypes) {
                    select ot.toUpper(): ObjType {
                        when ObjType.PDARRAY {
                            var dtype: C_HDF5.hid_t;
                            select str2dtype(dt) {
                                when DType.Int64 {
                                    var key_entry = st.lookup(name);
                                    var key = toSymEntry(toGenSymEntry(key_entry), int);

                                    // localize permutation and write dataset
                                    var localkey: [0..#key.size] int = key.a;
                                    writeLocalDset(file_id, "/%s/KEY_%i".format(group, i), c_ptrTo(localkey), key.size, int);
                                    dtype = getDataType(int);
                                }
                                when DType.UInt64 {
                                    var key_entry = st.lookup(name);
                                    var key = toSymEntry(toGenSymEntry(key_entry), uint);

                                    // localize permutation and write dataset
                                    var localkey: [0..#key.size] uint = key.a;
                                    writeLocalDset(file_id, "/%s/KEY_%i".format(group, i), c_ptrTo(localkey), key.size, uint);
                                    dtype = getDataType(uint);
                                }
                                when DType.Float64 {
                                    var key_entry = st.lookup(name);
                                    var key = toSymEntry(toGenSymEntry(key_entry), real);

                                    // localize permutation and write dataset
                                    var localkey: [0..#key.size] real = key.a;
                                    writeLocalDset(file_id, "/%s/KEY_%i".format(group, i), c_ptrTo(localkey), key.size, real);
                                    dtype = getDataType(real);
                                }
                                when DType.Bool {
                                    var key_entry = st.lookup(name);
                                    var key = toSymEntry(toGenSymEntry(key_entry), bool);

                                    // localize permutation and write dataset
                                    var localkey: [0..#key.size] bool = key.a;
                                    writeLocalDset(file_id, "/%s/KEY_%i".format(group, i), c_ptrTo(localkey), key.size, bool);
                                    dtype = C_HDF5.H5T_NATIVE_HBOOL;
                                }
                                otherwise {
                                    throw getErrorWithContext(
                                    msg="Unsupported DType %s".format(str2dtype(dt)),
                                    lineNumber=getLineNumber(),
                                    routineName=getRoutineName(), 
                                    moduleName=getModuleName(),
                                    errorClass="IllegalArgumentError");
                                }
                            }
                            writeArkoudaMetaData(file_id, "/%s/KEY_%i".format(group, i), "pdarray", dtype);
                        }
                        when ObjType.STRINGS {
                            // create/overwrite the group
                            validateGroup(file_id, f, "%s/KEY_%i".format(group, i), overwrite);
                            var key_entry: SegStringSymEntry = toSegStringSymEntry(st.lookup(name));
                            var key = new SegString("", key_entry);
                            writeSegmentedLocalDset(file_id, "/%s/KEY_%i".format(group, i), key.values, key.offsets, true, uint(8));
                            writeArkoudaMetaData(file_id, "/%s/KEY_%i".format(group, i), "Strings", getHDF5Type(uint(8)));
                        }
                        when ObjType.CATEGORICAL {
                            // create/overwrite the group
                            validateGroup(file_id, f, "%s/KEY_%i".format(group, i), overwrite);
                            var cat_comps = jsonToMap(name);
                            var codes_entry = st.lookup(cat_comps["codes"]);
                            var codes = toSymEntry(toGenSymEntry(codes_entry), int);
                            var cat_entry:SegStringSymEntry = toSegStringSymEntry(st.lookup(cat_comps["categories"]));
                            var cats = new SegString("", cat_entry);
                            var naCodes_entry = st.lookup(cat_comps["NA_codes"]);
                            var naCodes = toSymEntry(toGenSymEntry(naCodes_entry), int);
                            writeLocalCategoricalRequiredData(file_id, f, "%s/KEY_%i".format(group, i), codes, cats, naCodes, overwrite);

                            if cat_comps.contains["permutation"] && cat_comps.contains["segments"] {
                                writeLocalCategoricalOptionalData(file_id, "%s/KEY_%i".format(group, i), cat_comps["permutation"], cat_comps["segments"], st);
                            }
                            writeArkoudaMetaData(file_id, "/%s/KEY_%i".format(group, i), "Categorical", getHDF5Type(uint(8)));
                        }
                        otherwise {
                            throw getErrorWithContext(
                            msg="Unsupported ObjType %s".format(ot: string),
                            lineNumber=getLineNumber(),
                            routineName=getRoutineName(), 
                            moduleName=getModuleName(),
                            errorClass="IllegalArgumentError");
                        }
                    }
                }
                // write attributes for arkouda meta info
                writeGroupByMetaData(file_id, group, objType: string, num_keys);
                C_HDF5.H5Fclose(file_id);

            }
            when MULTI_FILE {
                var filenames = prepFiles(filename, mode, perm.a);

                // need to add the group to all files
                coforall (loc, idx) in zip(perm.a.targetLocales(), filenames.domain) do on loc {
                    const localeFilename = filenames[idx];
                    h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                "%s exists? %t".format(localeFilename, exists(localeFilename)));

                    var file_id = C_HDF5.H5Fopen(localeFilename.c_str(), C_HDF5.H5F_ACC_RDWR, C_HDF5.H5P_DEFAULT);
                    defer { // Close the file on scope exit
                        C_HDF5.H5Fclose(file_id);
                    }

                    // create the group and generate metadata
                    validateGroup(file_id, localeFilename, group, overwrite);
                    writeGroupByMetaData(file_id, group, objType: string, num_keys); 
                }

                // write groupby.segments
                writeDistDset(filenames, "/%s/%s".format(group, SEGMENTS_NAME), "pdarray", overwrite, segments.a, st);

                //write groupby.permutation
                writeDistDset(filenames, "/%s/%s".format(group, PERMUTATION_NAME), "pdarray", overwrite, perm.a, st);

                // write groupby._uki
                writeDistDset(filenames, "/%s/%s".format(group, UKI_NAME), "pdarray", overwrite, uki.a, st);

                // loop keys and create/write dataset for each
                for (i, name, ot, dt) in zip(0..#num_keys, key_names, key_objTypes, key_dtypes) {
                    select ot.toUpper(): ObjType {
                        when ObjType.PDARRAY {
                            var entry = st.lookup(name);
                            select str2dtype(dt) {
                                when DType.Int64 {
                                    var e = toSymEntry(toGenSymEntry(entry), int);
                                    writeDistDset(filenames, "%s/KEY_%i".format(group, i), ot: string, overwrite, e.a, st);
                                }
                                when DType.UInt64 {
                                    var e = toSymEntry(toGenSymEntry(entry), uint);
                                    writeDistDset(filenames, "%s/KEY_%i".format(group, i), ot: string, overwrite, e.a, st);
                                }
                                when DType.Float64 {
                                    var e = toSymEntry(toGenSymEntry(entry), real);
                                    writeDistDset(filenames, "%s/KEY_%i".format(group, i), ot: string, overwrite, e.a, st);
                                }
                                when DType.Bool {
                                    var e = toSymEntry(toGenSymEntry(entry), bool);
                                    writeDistDset(filenames, "%s/KEY_%i".format(group, i), ot: string, overwrite, e.a, st);
                                }
                                otherwise {
                                    throw getErrorWithContext(
                                    msg="Unsupported DType %s".format(str2dtype(dt)),
                                    lineNumber=getLineNumber(),
                                    routineName=getRoutineName(), 
                                    moduleName=getModuleName(),
                                    errorClass="IllegalArgumentError");
                                }
                            }
                        }
                        when ObjType.STRINGS {
                            var entry:SegStringSymEntry = toSegStringSymEntry(st.lookup(name));
                            var segString = new SegString("", entry);
                            var valEntry = segString.values;
                            var segEntry = segString.offsets;
                            writeSegmentedDistDset(filenames, "/%s/KEY_%i".format(group, i), ot: string, overwrite, valEntry.a, segEntry.a, st, uint(8));
                        }
                        when ObjType.CATEGORICAL {
                            var cat_comps = jsonToMap(name);
                            var codes_entry = st.lookup(cat_comps["codes"]);
                            var codes = toSymEntry(toGenSymEntry(codes_entry), int);
                            var cat_entry:SegStringSymEntry = toSegStringSymEntry(st.lookup(cat_comps["categories"]));
                            var cats = new SegString("", cat_entry);
                            var naCodes_entry = st.lookup(cat_comps["NA_codes"]);
                            var naCodes = toSymEntry(toGenSymEntry(naCodes_entry), int);

                            // need to add the group to all files
                            coforall (loc, idx) in zip(codes.a.targetLocales(), filenames.domain) do on loc {
                                const localeFilename = filenames[idx];
                                var file_id = C_HDF5.H5Fopen(localeFilename.c_str(), C_HDF5.H5F_ACC_RDWR, C_HDF5.H5P_DEFAULT);
                                defer { // Close the file on scope exit
                                    C_HDF5.H5Fclose(file_id);
                                }

                                // create the group and generate metadata
                                validateGroup(file_id, localeFilename, "%s/KEY_%i".format(group, i), overwrite);
                                writeArkoudaMetaData(file_id, "%s/KEY_%i".format(group, i), ot:string, getHDF5Type(uint(8))); 
                            }

                            // write codes
                            writeDistDset(filenames, "/%s/KEY_%i/%s".format(group, i, CODES_NAME), "pdarray", overwrite, codes.a, st);

                            // write categories
                            writeSegmentedDistDset(filenames, "/%s/KEY_%i/%s".format(group, i, CATEGORIES_NAME), "strings", overwrite, cats.values.a, cats.offsets.a, st, uint(8));

                            // write NA Codes
                            writeDistDset(filenames,"/%s/KEY_%i/%s".format(group, i, NACODES_NAME), "pdarray", overwrite, naCodes.a, st);

                            // writes perms and segs if they exist
                            if cat_comps.contains["permutation"] && cat_comps.contains["segments"] {
                                var cat_perm_entry = st.lookup(cat_comps["permutation"]);
                                var cat_perm = toSymEntry(toGenSymEntry(cat_perm_entry), int);
                                var segment_entry = st.lookup(cat_comps["segments"]);
                                var segs = toSymEntry(toGenSymEntry(segment_entry), int);
                                writeDistDset(filenames, "/%s/KEY_%i/%s".format(group, i, PERMUTATION_NAME), "pdarray", overwrite, cat_perm.a, st);
                                writeDistDset(filenames, "/%s/KEY_%i/%s".format(group, i, SEGMENTS_NAME), "pdarray", overwrite, segs.a, st);
                            }
                        }
                        otherwise {
                            throw getErrorWithContext(
                            msg="Unsupported ObjType %s".format(ot: string),
                            lineNumber=getLineNumber(),
                            routineName=getRoutineName(), 
                            moduleName=getModuleName(),
                            errorClass="IllegalArgumentError");
                        }
                    }
                }
            }
            otherwise {
                throw getErrorWithContext(
                           msg="Unknown file format. Expecting 0 (single file) or 1 (file per locale). Found %i".format(file_format),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
            }
        }
    }

    /*
        Parse and exectue tohdf message.
        Determines the type of the object to be written and calls the corresponding write functionality.
    */
    proc tohdfMsg(cmd: string, msgArgs: borrowed MessageArgs, st: borrowed SymTab): MsgTuple throws {
        var objType: ObjType = msgArgs.getValueOf("objType").toUpper(): ObjType;

        select objType {
            when ObjType.ARRAYVIEW {
                // call handler for arrayview write msg
                arrayView_tohdfMsg(msgArgs, st);
            }
            when ObjType.PDARRAY {
                // call handler for pdarray write
                pdarray_tohdfMsg(msgArgs, st);
            }
            when ObjType.STRINGS {
                // call handler for strings write
                strings_tohdfMsg(msgArgs, st);
            }
            when ObjType.SEGARRAY {
                // call handler for segarray write
                segarray_tohdfMsg(msgArgs, st);
            }
            when ObjType.CATEGORICAL {
                categorical_tohdfMsg(msgArgs, st);
            }
            when ObjType.GROUPBY {
                // call handler for groupby write
                groupby_tohdfMsg(msgArgs, st);
            }
            otherwise {
                var errorMsg = "Unable to write object type %s to HDF5 file.".format(objType);
                h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                return new MsgTuple(errorMsg, MsgType.ERROR);
            }
        }
        var repMsg: string = "Dataset written successfully!";
        return new MsgTuple(repMsg, MsgType.NORMAL);
    }

    /*
     * Returns boolean indicating whether the file is a valid HDF5 file.
     * Note: if the file cannot be opened due to permissions, throws
     * a PermissionError
     */
    proc isHdf5File(filename : string) : bool throws {
        var isHdf5 = C_HDF5.H5Fis_hdf5(filename.c_str());
        
        if isHdf5 == 1 {
            return true;
        } else if isHdf5 == 0 {
            return false;
        }

        var errorMsg="%s cannot be opened to check if hdf5, \
                           check file permissions or format".format(filename);
        throw getErrorWithContext(
                       msg=errorMsg,
                       lineNumber=getLineNumber(),
                       routineName=getRoutineName(), 
                       moduleName=getModuleName(),
                       errorClass="PermissionError");      
    }

    /**
     * Simulate h5ls call by using HDF5 API (top level datasets and groups only, not recursive)
     * This uses both internal call back functions as well as exter c functions defined above to
     * work with the HDF5 API and handle the the data objects it passes between calls as opaque void*
     * which can't be used directly in chapel code.
     */
    proc simulate_h5ls(fid:C_HDF5.hid_t):string throws {
        /** Note: I tried accessing a list inside my inner procs but it leads to segfaults.
         * It only works if the thing you are trying to access is a global.  This is some type
         * of strange interplay between C & chapel as straight chapel didn't cause problems.
         * var items = new list(string);  
         */

        /**
         * This is an H5Literate call-back function, c_helper funcs are used to process data in void*
         * this proc counts the number of of HDF5 groups/datasets under the root, non-recursive
         */
        proc _get_item_count(loc_id:C_HDF5.hid_t, name:c_void_ptr, info:c_void_ptr, data:c_void_ptr) {
            var obj_name = name:c_string;
            var obj_type:C_HDF5.H5O_type_t;
            var status:C_HDF5.H5O_type_t = c_get_HDF5_obj_type(loc_id, obj_name, c_ptrTo(obj_type));
            if (obj_type == C_HDF5.H5O_TYPE_GROUP || obj_type == C_HDF5.H5O_TYPE_DATASET) {
                c_incrementCounter(data);
            }
            return 0; // to continue iteration
        }

        /**
         * This is an H5Literate call-back function, c_helper funcs are used to process data in void*
         * this proc builds string of HDF5 group/dataset objects names under the root, non-recursive
         */
        proc _simulate_h5ls(loc_id:C_HDF5.hid_t, name:c_void_ptr, info:c_void_ptr, data:c_void_ptr) {
            var obj_name = name:c_string;
            var obj_type:C_HDF5.H5O_type_t;
            var status:C_HDF5.H5O_type_t = c_get_HDF5_obj_type(loc_id, obj_name, c_ptrTo(obj_type));
            if (obj_type == C_HDF5.H5O_TYPE_GROUP || obj_type == C_HDF5.H5O_TYPE_DATASET) {
                // items.pushBack(obj_name:string); This doesn't work unless items is global
                c_append_HDF5_fieldname(data, obj_name);
            }
            return 0; // to continue iteration
        }
        
        var idx_p:C_HDF5.hsize_t; // This is the H5Literate index counter
        
        // First iteration to get the item count so we can ballpark the char* allocation
        var nfields:c_int = 0:c_int;
        C_HDF5.H5Literate(fid, C_HDF5.H5_INDEX_NAME, C_HDF5.H5_ITER_NATIVE, idx_p, c_ptrTo(_get_item_count), c_ptrTo(nfields));
        
        // Allocate space for array of strings
        var c_field_names = c_calloc(c_char, 255 * nfields);
        idx_p = 0:C_HDF5.hsize_t; // reset our iteration counter
        C_HDF5.H5Literate(fid, C_HDF5.H5_INDEX_NAME, C_HDF5.H5_ITER_NATIVE, idx_p, c_ptrTo(_simulate_h5ls), c_field_names);
        var pos = c_strlen(c_field_names):int;
        var items = string.createCopyingBuffer(c_field_names, pos, pos+1);
        c_free(c_field_names);
        return items;
    }

    proc lshdfMsg(cmd: string, msgArgs: borrowed MessageArgs, st: borrowed SymTab): MsgTuple throws {
        var repMsg: string;

        // Retrieve filename from payload
        var filename: string = msgArgs.getValueOf("filename");
        if filename.isEmpty() {
            var errorMsg = "Filename was Empty";
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(errorMsg, MsgType.ERROR);
        }

        // If the filename represents a glob pattern, retrieve the locale 0 filename
        if isGlobPattern(filename) {
            // Attempt to interpret filename as a glob expression and ls the first result
            var tmp = glob(filename);
            h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                      "glob-expanded filename: %s to size: %i files".format(filename, tmp.size));

            if tmp.size <= 0 {
                var errorMsg = "Cannot retrieve filename from glob expression %s, check file name or format".format(filename);
                h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                return new MsgTuple(errorMsg, MsgType.ERROR);
            }
            
            // Set filename to globbed filename corresponding to locale 0
            filename = tmp[tmp.domain.first];
        }
        
        // Check to see if the file exists. If not, return an error message
        if !exists(filename) {
            var errorMsg = "File %s does not exist in a location accessible to Arkouda".format(filename);
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(errorMsg,MsgType.ERROR);
        } 

        if !isHdf5File(filename) {
            var errorMsg = "File %s is not an HDF5 file".format(filename);
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(errorMsg,MsgType.ERROR);
        }
        
        try {

            var file_id = C_HDF5.H5Fopen(filename.c_str(), C_HDF5.H5F_ACC_RDONLY, C_HDF5.H5P_DEFAULT);
            defer { C_HDF5.H5Fclose(file_id); } // ensure file is closed
            repMsg = simulate_h5ls(file_id);
            var items = new list(repMsg.split(",")); // convert to json

            repMsg = "%jt".format(items);
        } catch e : Error {
            var errorMsg = "Failed to process HDF5 file %t".format(e.message());
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(errorMsg, MsgType.ERROR);
        }

        return new MsgTuple(repMsg, MsgType.NORMAL);
    }

    /*
     *  Get the subdomains of the distributed array represented by each file, 
     *  as well as the total length of the array. 
     */
    proc get_subdoms(filenames: [?FD] string, dsetName: string, validFiles: [] bool) throws {
        use CTypes;

        var lengths: [FD] int;
        var skips = new set(string); // Case where there is no data in the file for this dsetName
        for (i, filename, isValid) in zip(FD, filenames, validFiles) {
            try {
                // if file had and error, it should be skipped.
                if !isValid {
                    skips.add(filename);
                    h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                        "Adding invalid file to skips, %s".format(filename));
                    continue;
                }
                var file_id = C_HDF5.H5Fopen(filename.c_str(), C_HDF5.H5F_ACC_RDONLY, 
                                           C_HDF5.H5P_DEFAULT);
                defer { // Close the file on exit
                    C_HDF5.H5Fclose(file_id);
                }

                var dims: [0..#1] C_HDF5.hsize_t; // Only rank 1 for now

                // Read array length into dims[0]
                C_HDF5.HDF5_WAR.H5LTget_dataset_info_WAR(file_id, dsetName.c_str(), 
                                           c_ptrTo(dims), nil, nil);
                lengths[i] = dims[0]: int;
                if lengths[i] == 0 {
                    skips.add(filename);
                    h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                        "Adding filename:%s to skips, dsetName:%s, dims[0]:%t".format(filename, dsetName, dims[0]));
                }

            } catch e: Error {
                throw getErrorWithContext(
                             msg="in getting dataset info %s".format(e.message()),
                             lineNumber=getLineNumber(), 
                             routineName=getRoutineName(), 
                             moduleName=getModuleName(), 
                             errorClass='WriteModeError'
                );
            }
        }
        // Compute subdomain of master array contained in each file
        var subdoms: [FD] domain(1);
        var offset = 0;
        for i in FD {
            subdoms[i] = {offset..#lengths[i]};
            offset += lengths[i];
        }
        return (subdoms, (+ reduce lengths), skips);
    }

    /* 
        Write data from HDF5 dataset into a distributed array.
        This function gets called when A is a BlockDist or DefaultRectangular array. 
    */
    proc read_files_into_distributed_array(A, filedomains: [?FD] domain(1), 
                                                 filenames: [FD] string, dsetName: string, skips: set(string)) throws 
        where (MyDmap == Dmap.blockDist || MyDmap == Dmap.defaultRectangular)
    {
        h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                "entry.a.targetLocales() = %t".format(A.targetLocales()));
        h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                "Filedomains: %t".format(filedomains));
        h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                "skips: %t".format(skips));

        coforall loc in A.targetLocales() do on loc {
            // Create local copies of args
            var locFiles = filenames;
            var locFiledoms = filedomains;
            /* On this locale, find all files containing data that belongs in
                this locale's chunk of A */
            for (filedom, filename) in zip(locFiledoms, locFiles) {
                var isopen = false;
                var file_id: C_HDF5.hid_t;
                var dataset: C_HDF5.hid_t;

                if (skips.contains(filename)) {
                    h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                            "File %s does not contain data for this dataset, skipping".format(filename));
                } else {
                    // Look for overlap between A's local subdomains and this file
                    for locdom in A.localSubdomains() {
                        const intersection = domain_intersection(locdom, filedom);
                        if intersection.size > 0 {
                            // Only open the file once, even if it intersects with many local subdomains
                            if !isopen {
                                file_id = C_HDF5.H5Fopen(filename.c_str(), C_HDF5.H5F_ACC_RDONLY, 
                                                                                        C_HDF5.H5P_DEFAULT);  
                                try! dataset = C_HDF5.H5Dopen(file_id, dsetName.localize().c_str(), C_HDF5.H5P_DEFAULT);
                                isopen = true;
                            }
                            // do A[intersection] = file[intersection - offset]
                            var dataspace = C_HDF5.H5Dget_space(dataset);
                            var dsetOffset = (intersection.low - filedom.low): C_HDF5.hsize_t;
                            var dsetStride = intersection.stride: C_HDF5.hsize_t;
                            var dsetCount = intersection.size: C_HDF5.hsize_t;
                            C_HDF5.H5Sselect_hyperslab(dataspace, C_HDF5.H5S_SELECT_SET, c_ptrTo(dsetOffset), 
                                                            c_ptrTo(dsetStride), c_ptrTo(dsetCount), nil);
                            var memOffset = 0: C_HDF5.hsize_t;
                            var memStride = 1: C_HDF5.hsize_t;
                            var memCount = intersection.size: C_HDF5.hsize_t;
                            var memspace = C_HDF5.H5Screate_simple(1, c_ptrTo(memCount), nil);
                            C_HDF5.H5Sselect_hyperslab(memspace, C_HDF5.H5S_SELECT_SET, c_ptrTo(memOffset), 
                                                            c_ptrTo(memStride), c_ptrTo(memCount), nil);

                            h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                    "Locale %t intersection %t dataset slice %t".format(loc,intersection,
                                    (intersection.low - filedom.low, intersection.high - filedom.low)));

                            /*
                            * The fact that intersection is a subset of a local subdomain means
                            * there should be no communication in the read
                            */
                            local {
                                C_HDF5.H5Dread(dataset, getHDF5Type(A.eltType), memspace, 
                                        dataspace, C_HDF5.H5P_DEFAULT, 
                                        c_ptrTo(A.localSlice(intersection)));
                            }
                            C_HDF5.H5Sclose(memspace);
                            C_HDF5.H5Sclose(dataspace);
                        }
                    }
                }
                if isopen {
                    C_HDF5.H5Dclose(dataset);
                    C_HDF5.H5Fclose(file_id);
                }
            }
        }
    }

    /*
        Determine if the dataset contains boolean values
    */
    proc isBoolDataset(filename: string, dset: string): bool throws {
        var file_id = C_HDF5.H5Fopen(filename.c_str(), C_HDF5.H5F_ACC_RDONLY, 
                                           C_HDF5.H5P_DEFAULT);
        defer { // Close the file on exit
            C_HDF5.H5Fclose(file_id);
        }
        var boolDataset: bool;
        try {
            var dset_id: C_HDF5.hid_t = C_HDF5.H5Dopen(file_id, dset.c_str(), C_HDF5.H5P_DEFAULT);
            var isBool: int;
            if C_HDF5.H5Aexists_by_name(dset_id, ".".c_str(), "isBool", C_HDF5.H5P_DEFAULT) > 0 {
                var isBool_id: C_HDF5.hid_t = C_HDF5.H5Aopen_by_name(dset_id, ".".c_str(), "isBool", C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
                C_HDF5.H5Aread(isBool_id, getHDF5Type(int), c_ptrTo(isBool));
                boolDataset = if isBool == 1 then true else false;
            }
            else{
                boolDataset = false;
            }
            C_HDF5.H5Dclose(dset_id);
        } catch e: Error {
            /*
             * If there's an actual error, print it here. :TODO: revisit this
             * catch block after confirming the best way to handle HDF5 error
             */
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),
                        "checking if isBoolDataset %t with file %s".format(e.message()));
        }
        return boolDataset;
    }

    /**
     * inline proc to validate the range for our domain.
     * Valid domains must be increasing with the lower bound <= upper bound
     * :arg r: 1D domain
     * :type domain(1): one dimensional domain
     *
     * :returns: bool True iff the lower bound is less than or equal to upper bound
     */
    inline proc _isValidRange(r: domain(1)): bool {
        return r.low <= r.high;
    }

    proc fixupSegBoundaries(a: [?D] int, segSubdoms: [?fD] domain(1), valSubdoms: [fD] domain(1)) throws {
        if(1 == a.size) { // short circuit case where we only have one string/segment
            return;
        }
        var diffs: [fD] int; // Amount each region must be raised over previous region
        forall (i, sd, vd, d) in zip(fD, segSubdoms, valSubdoms, diffs) {
            // if we encounter a malformed subdomain i.e. {1..0} that means we encountered a file
            // that has no data for this SegString object, we can safely skip processing this file.
            if (_isValidRange(sd)) {
                d = vd.size;
            } else {
                h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                    "fD:%t segments subdom:%t is malformed signaling no segment data in file, skipping".format(i, sd));
            }
        }
        
        // compute amount to adjust 
        var adjustments = (+ scan diffs) - diffs;
        coforall loc in a.targetLocales() do on loc {
            forall(sd, adj) in zip(segSubdoms, adjustments) {
                for locdom in a.localSubdomains() {
                    const intersection = domain_intersection(locdom, sd);
                    if intersection.size > 0 {
                        // adjust offset of the segment based on the sizes of the segments preceeding it
                        a[intersection] += adj;
                    }
                }
            }
        }
    }

    /*
        Read an ArrayView object from the files provided into a distributed array
    */
    proc arrayView_readhdfMsg(filenames: [?fD] string, dset: string, dataclass, bytesize: int, isSigned: bool, validFiles: [] bool, st: borrowed SymTab): (string, string, string) throws {
        var subdoms: [fD] domain(1);
        var skips = new set(string);
        var len: int;
        (subdoms, len, skips) = get_subdoms(filenames, dset, validFiles);

        var file_id = C_HDF5.H5Fopen(filenames[0].c_str(), C_HDF5.H5F_ACC_RDONLY, 
                                           C_HDF5.H5P_DEFAULT);
        var dset_id: C_HDF5.hid_t = C_HDF5.H5Dopen(file_id, dset.c_str(), C_HDF5.H5P_DEFAULT);

        // check if rank is attr and then get.
        var rank: int;
        if C_HDF5.H5Aexists_by_name(dset_id, ".".c_str(), "Rank", C_HDF5.H5P_DEFAULT) > 0 {
            var rank_id: C_HDF5.hid_t = C_HDF5.H5Aopen_by_name(dset_id, ".".c_str(), "Rank", C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
            var attr_type: C_HDF5.hid_t = C_HDF5.H5Aget_type(rank_id);
            C_HDF5.H5Aread(rank_id, getHDF5Type(int), c_ptrTo(rank));
        }
        else{
            // Return error that file does not have required attrs
            var errorMsg = "Rank Attribute was not located in %s. This attribute is required to process multi-dimensional data.".format(filenames[0]);
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            throw getErrorWithContext(
                             msg=errorMsg,
                             lineNumber=getLineNumber(), 
                             routineName=getRoutineName(), 
                             moduleName=getModuleName(), 
                             errorClass='AttributeNotFoundError');
        }

        // check if shape attr is present and read it
        var shape: [0..#rank] int;
        if C_HDF5.H5Aexists_by_name(dset_id, ".".c_str(), "Shape", C_HDF5.H5P_DEFAULT) > 0 {
            var shape_id: C_HDF5.hid_t = C_HDF5.H5Aopen_by_name(dset_id, ".".c_str(), "Shape", C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
            var attr_type: C_HDF5.hid_t = C_HDF5.H5Aget_type(shape_id);
            C_HDF5.H5Aread(shape_id, getHDF5Type(shape.eltType), c_ptrTo(shape));
        }
        else {
            // Return error that file does not have required attrs
            var errorMsg = "Shape Attribute was not located in %s. This attribute is required to process multi-dimensional data.".format(filenames[0]);
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            throw getErrorWithContext(
                             msg=errorMsg,
                             lineNumber=getLineNumber(), 
                             routineName=getRoutineName(), 
                             moduleName=getModuleName(), 
                             errorClass='AttributeNotFoundError');
        }

        C_HDF5.H5Dclose(dset_id);
        C_HDF5.H5Fclose(file_id);
        
        var sname = st.nextName();
        st.addEntry(sname, new shared SymEntry(shape));
        select dataclass {
            when C_HDF5.H5T_INTEGER {
                // identify the index of the first valid file
                var (v, idx) = maxloc reduce zip(validFiles, validFiles.domain);
                if (!isSigned && 8 == bytesize) {
                    var entryUInt = new shared SymEntry(len, uint);
                    h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(), "Initialized uint entry for dataset %s".format(dset));
                    read_files_into_distributed_array(entryUInt.a, subdoms, filenames, dset, skips);
                    var rname = st.nextName();
                    if isBoolDataset(filenames[idx], dset) {
                        var entryBool = new shared SymEntry(len, bool);
                        entryBool.a = entryUInt.a:bool;
                        st.addEntry(rname, entryBool);
                    } else {
                        // Not a boolean dataset, so add original SymEntry to SymTable
                        st.addEntry(rname, entryUInt);
                    }
                    st.addEntry(rname, entryUInt);
                    return (dset, "ArrayView", "%s+%s".format(rname, sname));
                }
                else {
                    var entryInt = new shared SymEntry(len, int);
                    h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(), "Initialized int entry for dataset %s".format(dset));
                    read_files_into_distributed_array(entryInt.a, subdoms, filenames, dset, skips);
                    var rname = st.nextName();
                    if isBoolDataset(filenames[idx], dset) {
                        var entryBool = new shared SymEntry(len, bool);
                        entryBool.a = entryInt.a:bool;
                        st.addEntry(rname, entryBool);
                    } else {
                        // Not a boolean dataset, so add original SymEntry to SymTable
                        st.addEntry(rname, entryInt);
                    }
                    return (dset, "ArrayView", "%s+%s".format(rname, sname));
                }
            }
            when C_HDF5.H5T_FLOAT {
                var entryReal = new shared SymEntry(len, real);
                h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                                                    "Initialized float entry");
                read_files_into_distributed_array(entryReal.a, subdoms, filenames, dset, skips);
                var rname = st.nextName();
                st.addEntry(rname, entryReal);
                return (dset, "ArrayView", "%s+%s".format(rname, sname));
            }
            otherwise {
                var errorMsg = "detected unhandled datatype: objType? ArrayView, class %i, size %i, " +
                                "signed? %t".format(dataclass, bytesize, isSigned);
                h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                throw getErrorWithContext(
                            msg=errorMsg,
                            lineNumber=getLineNumber(), 
                            routineName=getRoutineName(), 
                            moduleName=getModuleName(), 
                            errorClass='UnhandledDatatypeError');
            }
        }
    }

    /*
        Read an pdarray object from the files provided into a distributed array
    */
    proc readPdarrayFromFile(filenames: [?fD] string, dset: string, dataclass, bytesize: int, isSigned: bool, validFiles: [] bool, st: borrowed SymTab): string throws {
        var rname: string;
        var subdoms: [fD] domain(1);
        var skips = new set(string);
        var len: int;
        (subdoms, len, skips) = get_subdoms(filenames, dset, validFiles);
        select dataclass {
            when C_HDF5.H5T_INTEGER {
                // identify the index of the first valid file
                var (v, idx) = maxloc reduce zip(validFiles, validFiles.domain);
                if (!isSigned && 8 == bytesize) {
                    var entryUInt = new shared SymEntry(len, uint);
                    h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(), "Initialized uint entry for dataset %s".format(dset));
                    read_files_into_distributed_array(entryUInt.a, subdoms, filenames, dset, skips);
                    rname = st.nextName();
                    if isBoolDataset(filenames[idx], dset) {
                        var entryBool = new shared SymEntry(len, bool);
                        entryBool.a = entryUInt.a:bool;
                        st.addEntry(rname, entryBool);
                    } else {
                        // Not a boolean dataset, so add original SymEntry to SymTable
                        st.addEntry(rname, entryUInt);
                    }
                }
                else {
                    var entryInt = new shared SymEntry(len, int);
                    h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(), "Initialized int entry for dataset %s".format(dset));
                    read_files_into_distributed_array(entryInt.a, subdoms, filenames, dset, skips);
                    rname = st.nextName();
                    if isBoolDataset(filenames[idx], dset) {
                        var entryBool = new shared SymEntry(len, bool);
                        entryBool.a = entryInt.a:bool;
                        st.addEntry(rname, entryBool);
                    } else {
                        // Not a boolean dataset, so add original SymEntry to SymTable
                        st.addEntry(rname, entryInt);
                    }
                }
            }
            when C_HDF5.H5T_FLOAT {
                var entryReal = new shared SymEntry(len, real);
                h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                                                    "Initialized float entry");
                read_files_into_distributed_array(entryReal.a, subdoms, filenames, dset, skips);
                rname = st.nextName();
                st.addEntry(rname, entryReal);
            }
            otherwise {
                var errorMsg = "detected unhandled datatype: objType? pdarray, class %i, size %i, " +
                                "signed? %t".format(dataclass, bytesize, isSigned);
                h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                throw getErrorWithContext(
                            msg=errorMsg,
                            lineNumber=getLineNumber(), 
                            routineName=getRoutineName(), 
                            moduleName=getModuleName(), 
                            errorClass='UnhandledDatatypeError');
            }
        }
        return rname;
    }

    proc pdarray_readhdfMsg(filenames: [?fD] string, dset: string, dataclass, bytesize: int, isSigned: bool, validFiles: [] bool, st: borrowed SymTab): (string, string, string) throws {
        var pda_name = readPdarrayFromFile(filenames, dset, dataclass, bytesize, isSigned, validFiles, st);
        return (dset, "pdarray", pda_name);
    }

    /*
        Read an strings object from the files provided into a distributed array
    */
    proc readStringsFromFile(filenames: [?fD] string, dset: string, dataclass, bytesize: int, isSigned: bool, calcStringOffsets: bool, validFiles: [] bool, st: borrowed SymTab) throws {
        var subdoms: [fD] domain(1);
        var segSubdoms: [fD] domain(1);
        var skips = new set(string);
        var len: int;
        var nSeg: int;
        if (!calcStringOffsets) {
            (segSubdoms, nSeg, skips) = get_subdoms(filenames, dset + "/" + SEGMENTED_OFFSET_NAME, validFiles);
        }
        (subdoms, len, skips) = get_subdoms(filenames, dset + "/" + SEGMENTED_VALUE_NAME, validFiles);

        if (bytesize != 1) || isSigned {
            var errorMsg = "Error: detected unhandled datatype: objType? SegString, class %i, size %i, signed? %t".format(
                                    dataclass, bytesize, isSigned);
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            throw getErrorWithContext(
                            msg=errorMsg,
                            lineNumber=getLineNumber(), 
                            routineName=getRoutineName(), 
                            moduleName=getModuleName(), 
                            errorClass='UnhandledDatatypeError');
        }

        // Load the strings bytes/values first
        var entryVal = new shared SymEntry(len, uint(8));
        read_files_into_distributed_array(entryVal.a, subdoms, filenames, dset + "/" + SEGMENTED_VALUE_NAME, skips);

        proc _buildEntryCalcOffsets(): shared SymEntry throws {
            var offsetsArray = segmentedCalcOffsets(entryVal.a, entryVal.a.domain);
            return new shared SymEntry(offsetsArray);
        }

        proc _buildEntryLoadOffsets() throws {
            var offsetsEntry = new shared SymEntry(nSeg, int);
            read_files_into_distributed_array(offsetsEntry.a, segSubdoms, filenames, dset + "/" + SEGMENTED_OFFSET_NAME, skips);
            fixupSegBoundaries(offsetsEntry.a, segSubdoms, subdoms);
            return offsetsEntry;
        }

        var entrySeg = if (calcStringOffsets || nSeg < 1 || !skips.isEmpty()) then _buildEntryCalcOffsets() else _buildEntryLoadOffsets();

        return assembleSegStringFromParts(entrySeg, entryVal, st);
    }

    proc strings_readhdfMsg(filenames: [?fD] string, dset: string, dataclass, bytesize: int, isSigned: bool, calcStringOffsets: bool, validFiles: [] bool, st: borrowed SymTab): (string, string, string) throws {
        var stringsEntry = readStringsFromFile(filenames, dset, dataclass, bytesize, isSigned, calcStringOffsets, validFiles, st);
        return (dset, "seg_string", "%s+%t".format(stringsEntry.name, stringsEntry.nBytes));
    }

    proc segarray_readhdfMsg(filenames: [?fD] string, dset: string, dataclass, bytesize: int, isSigned: bool, validFiles: [] bool, st: borrowed SymTab): (string, string, string) throws {        
        var valSubdoms: [fD] domain(1);
        var segSubdoms: [fD] domain(1);
        var skips = new set(string);
        var len: int;
        var nSeg: int;

        (segSubdoms, nSeg, skips) = get_subdoms(filenames, dset + "/" + SEGMENTED_OFFSET_NAME, validFiles);
        (valSubdoms, len, skips) = get_subdoms(filenames, dset + "/" + SEGMENTED_VALUE_NAME, validFiles);

        var rtnMap: map(string, string) = new map(string, string);

        var segDist = makeDistArray(nSeg, int);
        read_files_into_distributed_array(segDist, segSubdoms, filenames, dset + "/" + SEGMENTED_OFFSET_NAME, skips);
        fixupSegBoundaries(segDist, segSubdoms, valSubdoms);
        var sname = st.nextName();
        st.addEntry(sname, new shared SymEntry(segDist));
        rtnMap.add("segments", "created " + st.attrib(sname));

        var vname = st.nextName();
        select dataclass {
            when C_HDF5.H5T_INTEGER {
                var (v, idx) = maxloc reduce zip(validFiles, validFiles.domain);
                if isSigned {
                    // Load the values
                    var valDist = makeDistArray(len, int);
                    read_files_into_distributed_array(valDist, valSubdoms, filenames, dset + "/" + SEGMENTED_VALUE_NAME, skips);

                    if isBoolDataset(filenames[idx], dset + "/" + SEGMENTED_VALUE_NAME) {
                        var boolDist = makeDistArray(len, bool);
                        boolDist = valDist:bool;
                        st.addEntry(vname, new shared SymEntry(boolDist));
                    } else {
                        st.addEntry(vname, new shared SymEntry(valDist));
                    }                   
                } else {
                    var valDist = makeDistArray(len, uint);
                    read_files_into_distributed_array(valDist, valSubdoms, filenames, dset + "/" + SEGMENTED_VALUE_NAME, skips);

                    if isBoolDataset(filenames[idx], dset + "/" + SEGMENTED_VALUE_NAME) {
                        var boolDist = makeDistArray(len, bool);
                        boolDist = valDist:bool;
                        st.addEntry(vname, new shared SymEntry(boolDist));
                    } else {
                        st.addEntry(vname, new shared SymEntry(valDist));
                    } 
                }
            }
            when C_HDF5.H5T_FLOAT {
                var valDist = makeDistArray(len, real);
                read_files_into_distributed_array(valDist, valSubdoms, filenames, dset + "/" + SEGMENTED_VALUE_NAME, skips);
                
                st.addEntry(vname, new shared SymEntry(valDist));
            }
            otherwise {
                var errorMsg = "detected unhandled datatype: objType? segarray, class %i, size %i, " +
                                "signed? %t".format(dataclass, bytesize, isSigned);
                h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                throw getErrorWithContext(
                            msg=errorMsg,
                            lineNumber=getLineNumber(), 
                            routineName=getRoutineName(), 
                            moduleName=getModuleName(), 
                            errorClass='UnhandledDatatypeError');
            }
        }
        rtnMap.add("values", "created " + st.attrib(vname));
        
        return (dset, "seg_array", "%jt".format(rtnMap));
    }

    proc categorical_readhdfMsg(filenames: [?fD] string, dset: string, validFiles: [] bool, calcStringOffsets: bool, st: borrowed SymTab): (string, string, string) throws {
        var rtnMap: map(string, string);
        // domain and size info for codes
        var subdoms: [fD] domain(1);
        var skips = new set(string);
        var len: int;
        (subdoms, len, skips) = get_subdoms(filenames, "%s/%s".format(dset, CODES_NAME), validFiles);
        // read codes into distributed array
        var codes = makeDistArray(len, int);
        read_files_into_distributed_array(codes, subdoms, filenames, "%s/%s".format(dset, CODES_NAME), skips);
        // create symEntry
        var codesName = st.nextName();
        var codesEntry = new shared SymEntry(codes);
        st.addEntry(codesName, codesEntry);

        // read the categories
        var (objTypeList, dataclass, bytesize, isSigned) = get_info(filenames[0], "%s/%s".format(dset, CATEGORIES_NAME), calcStringOffsets);
        var cats = readStringsFromFile(filenames, "%s/%s".format(dset, CATEGORIES_NAME), dataclass, bytesize, isSigned, calcStringOffsets, validFiles, st);

        // read _akNACodes
        var nacodes_subdoms: [fD] domain(1);
        var nacodes_skips = new set(string);
        var nacodes_len: int;
        (nacodes_subdoms, nacodes_len, nacodes_skips) = get_subdoms(filenames, "%s/%s".format(dset, NACODES_NAME), validFiles);
        // read codes into distributed array
        var naCodes = makeDistArray(nacodes_len, int);
        read_files_into_distributed_array(naCodes, nacodes_subdoms, filenames, "%s/%s".format(dset, NACODES_NAME), nacodes_skips);
        // create symEntry
        var naCodesName = st.nextName();
        var naCodesEntry = new shared SymEntry(naCodes);
        st.addEntry(naCodesName, naCodesEntry);

        rtnMap.add("codes", "created " + st.attrib(codesEntry.name));
        rtnMap.add("categories", "created %s+created %t".format(st.attrib(cats.name), cats.nBytes));
        rtnMap.add("_akNAcode", "created " + st.attrib(naCodesEntry.name));
        
        // check first file for segments and permutation. If exist here should be everywhere
        var file_id = C_HDF5.H5Fopen(filenames[0].c_str(), C_HDF5.H5F_ACC_RDONLY, C_HDF5.H5P_DEFAULT);
        var segments_exist = C_HDF5.H5Lexists(file_id, "%s/%s".format(dset, SEGMENTS_NAME).c_str(), C_HDF5.H5P_DEFAULT);
        var perm_exists = C_HDF5.H5Lexists(file_id, "%s/%s".format(dset, PERMUTATION_NAME).c_str(), C_HDF5.H5P_DEFAULT);
        C_HDF5.H5Fclose(file_id);
        
        if segments_exist > 0 && perm_exists > 0 {
            // get domain and size info for segments
            var segs_subdoms: [fD] domain(1);
            var segs_skips = new set(string);
            var segs_len: int;
            (segs_subdoms, segs_len, segs_skips) = get_subdoms(filenames, "%s/%s".format(dset, SEGMENTS_NAME), validFiles);
            // read segments into distributed array
            var segments = makeDistArray(segs_len, int);
            read_files_into_distributed_array(segments, segs_subdoms, filenames, "%s/%s".format(dset, SEGMENTS_NAME), segs_skips);
            var segName = st.nextName();
            var segEntry = new shared SymEntry(segments);
            st.addEntry(segName, segEntry);

            // get domain and size info for permutation
            var perm_subdoms: [fD] domain(1);
            var perm_skips = new set(string);
            var perm_len: int;
            (perm_subdoms, perm_len, perm_skips) = get_subdoms(filenames, "%s/%s".format(dset, PERMUTATION_NAME), validFiles);
            // read permutation into distributed array
            var perm = makeDistArray(perm_len, int);
            read_files_into_distributed_array(perm, perm_subdoms, filenames, "%s/%s".format(dset, PERMUTATION_NAME), perm_skips);
            var permName = st.nextName();
            var permEntry = new shared SymEntry(perm);
            st.addEntry(permName, permEntry);

            rtnMap.add("segments", "created " + st.attrib(segEntry.name));
            rtnMap.add("permutation", "created " + st.attrib(permEntry.name));
        }
        return (dset, "categorical", "%jt".format(rtnMap));
    }

    proc groupby_readhdfMsg(filenames: [?fD] string, dset: string, validFiles: [] bool, calcStringOffsets: bool, st: borrowed SymTab): (string, string, string) throws {
        var rtnMap: map(string, string);
        // domain and size info for codes
        var perm_subdoms: [fD] domain(1);
        var perm_skips = new set(string);
        var perm_len: int;
        (perm_subdoms, perm_len, perm_skips) = get_subdoms(filenames, "%s/%s".format(dset, PERMUTATION_NAME), validFiles);
        var perm = makeDistArray(perm_len, int);
        read_files_into_distributed_array(perm, perm_subdoms, filenames, "%s/%s".format(dset, PERMUTATION_NAME), perm_skips);
        // create symEntry
        var permName = st.nextName();
        var permEntry = new shared SymEntry(perm);
        st.addEntry(permName, permEntry);

        var seg_subdoms: [fD] domain(1);
        var seg_skips = new set(string);
        var seg_len: int;
        (seg_subdoms, seg_len, seg_skips) = get_subdoms(filenames, "%s/%s".format(dset, SEGMENTS_NAME), validFiles);
        var segs = makeDistArray(seg_len, int);
        read_files_into_distributed_array(segs, seg_subdoms, filenames, "%s/%s".format(dset, SEGMENTS_NAME), seg_skips);
        // create symEntry
        var segName = st.nextName();
        var segEntry = new shared SymEntry(segs);
        st.addEntry(segName, segEntry);

        var uki_subdoms: [fD] domain(1);
        var uki_skips = new set(string);
        var uki_len: int;
        (uki_subdoms, uki_len, uki_skips) = get_subdoms(filenames, "%s/%s".format(dset, UKI_NAME), validFiles);
        var uki = makeDistArray(uki_len, int);
        read_files_into_distributed_array(uki, uki_subdoms, filenames, "%s/%s".format(dset, UKI_NAME), uki_skips);
        // create symEntry
        var ukiName = st.nextName();
        var ukiEntry = new shared SymEntry(uki);
        st.addEntry(ukiName, ukiEntry);

        rtnMap.add("permutation", "created " + st.attrib(permEntry.name));
        rtnMap.add("segments", "created " + st.attrib(segEntry.name));
        rtnMap.add("uki", "created " + st.attrib(ukiEntry.name));

        // read the number of keys attribute
        var file_id = C_HDF5.H5Fopen(filenames[0].c_str(), C_HDF5.H5F_ACC_RDONLY, C_HDF5.H5P_DEFAULT);
        var obj_id: C_HDF5.hid_t;
        obj_id = C_HDF5.H5Oopen(file_id, dset.c_str(), C_HDF5.H5P_DEFAULT);
        if obj_id < 0 {
            throw getErrorWithContext(
                           msg="Dataset, %s, not found.".format(dset),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
        }
        var numkeys: int = -1;
        if C_HDF5.H5Aexists_by_name(obj_id, ".".c_str(), "NumKeys", C_HDF5.H5P_DEFAULT) > 0 {
            var numkeys_id: C_HDF5.hid_t = C_HDF5.H5Aopen_by_name(obj_id, ".".c_str(), "NumKeys", C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
            C_HDF5.H5Aread(numkeys_id, getHDF5Type(int), c_ptrTo(numkeys));
            C_HDF5.H5Aclose(numkeys_id);
        }
        C_HDF5.H5Oclose(obj_id);

        if numkeys == -1 {
            throw getErrorWithContext(
                           msg="NumKeys attribute not found. Required for GroupBy Reads.",
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="RuntimeError");
        }

        for k in 0..#numkeys {
            //need to determine object type of the key to determine how to read it
            var keyObjType: ObjType;
            var dataclass: C_HDF5.hid_t;
            var bytesize: int;
            var isSigned: bool;
            var readDset: string;
            var readObjType: string;
            var readCreate: string;
            (keyObjType, dataclass, bytesize, isSigned) = get_info(filenames[0], "%s/KEY_%i".format(dset, k), calcStringOffsets);
            select keyObjType {
                when ObjType.PDARRAY {
                    var pda_name = readPdarrayFromFile(filenames, "%s/KEY_%i".format(dset, k), dataclass, bytesize, isSigned, validFiles, st);
                    readObjType = "pdarray";
                    readCreate = "created %s".format(st.attrib(pda_name));
                }
                when ObjType.STRINGS {
                    var segString = readStringsFromFile(filenames, "%s/KEY_%i".format(dset, k), dataclass, bytesize, isSigned, calcStringOffsets, validFiles, st);
                    readObjType = "seg_string";
                    readCreate = "created %s+created %t".format(st.attrib(segString.name), segString.nBytes);
                }
                when ObjType.CATEGORICAL {
                    (readDset, readObjType, readCreate) = categorical_readhdfMsg(filenames, "%s/KEY_%i".format(dset, k), validFiles, calcStringOffsets, st);
                }
                otherwise {
                    throw getErrorWithContext(
                           msg="Unsupported GroupBy key type, %s".format(keyObjType: string),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="TypeError");
                }
            }
            rtnMap.add("KEY_%i".format(k), "%s+|+%s".format(readObjType, readCreate));
        }
        C_HDF5.H5Fclose(file_id);
        return (dset, "groupby", "%jt".format(rtnMap));
    }

    /*
        Reads the ObjType attribute from a given object. 
        Returns the string representation
    */
    proc getObjType(file_id: C_HDF5.hid_t, dset: string): ObjType throws {
        var obj_id: C_HDF5.hid_t;

        obj_id = C_HDF5.H5Oopen(file_id, dset.c_str(), C_HDF5.H5P_DEFAULT);
        if obj_id < 0 {
            throw getErrorWithContext(
                           msg="Dataset, %s, not found.".format(dset),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="IllegalArgumentError");
        }

        var objType_int: int = -1;
        if C_HDF5.H5Aexists_by_name(obj_id, ".".c_str(), "ObjType", C_HDF5.H5P_DEFAULT) > 0 {
            var objType_id: C_HDF5.hid_t = C_HDF5.H5Aopen_by_name(obj_id, ".".c_str(), "ObjType", C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
            C_HDF5.H5Aread(objType_id, getHDF5Type(int), c_ptrTo(objType_int));
            C_HDF5.H5Aclose(objType_id);
        }
        else{
            // work around to handle old formats that do not store meta data.
            // It is assumed that any objects in this case are storing strings or pdarray
            if C_HDF5.H5Lexists(obj_id, SEGMENTED_VALUE_NAME.c_str(), C_HDF5.H5P_DEFAULT) > 0{
                // this means that the obj is a group and contains a strings obj
                objType_int = ObjType.STRINGS: int;
            }
            else {
                objType_int = ObjType.PDARRAY: int;
            }
        }
        // Close the open hdf5 objects
        C_HDF5.H5Oclose(obj_id);
        return objType_int:ObjType;
    }

    /*
     * Returns a tuple containing the data type, data class, and a 
     * boolean indicating whether the datatype is signed for the 
     * supplied file id and dataset name.
     */
    proc get_dataset_info(file_id, dsetName) throws {
        var dset = C_HDF5.H5Dopen(file_id, dsetName.c_str(),
                                                   C_HDF5.H5P_DEFAULT);
        if (dset < 0) {
            throw getErrorWithContext( 
                msg="dataset %s does not exist".format(dsetName), 
                lineNumber=getLineNumber(),
                routineName=getRoutineName(),
                moduleName=getModuleName(),
                errorClass='DatasetNotFoundError');
        }
        var datatype = C_HDF5.H5Dget_type(dset);
        var dataclass = C_HDF5.H5Tget_class(datatype);
        var bytesize = C_HDF5.H5Tget_size(datatype):int;
        var isSigned = (C_HDF5.H5Tget_sign(datatype) == C_HDF5.H5T_SGN_2);
        C_HDF5.H5Tclose(datatype);
        C_HDF5.H5Dclose(dset);
        return (dataclass, bytesize, isSigned);
    }

    /*
        Access information about the dataset in the given file.
        Used to detect errors when reading
    */
    proc get_info(filename: string, dsetName: string, calcStringOffsets: bool) throws {
        // Verify that the file exists
        if !exists(filename) {
            throw getErrorWithContext(
                           msg="The file %s does not exist".format(filename),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="FileNotFoundError");
        }

        /*
         * Checks to see if the file is indeed an HDF5 file. If there is a error
         * in opening file to check format, it is highly likely it is due to 
         * a permissions issue, so a PermissionError is thrown.
         */             
        if !isHdf5File(filename) {
            throw getErrorWithContext(
                           msg="%s is not an HDF5 file".format(filename),
                           lineNumber=getLineNumber(),
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(),
                           errorClass="NotHDF5FileError");        
        }

        var file_id = C_HDF5.H5Fopen(filename.c_str(), 
                                         C_HDF5.H5F_ACC_RDONLY, C_HDF5.H5P_DEFAULT);
                                         
        if file_id < 0 { // HF5open returns negative value on failure
            C_HDF5.H5Fclose(file_id);
            throw getErrorWithContext(
                           msg="in accessing %s HDF5 file content".format(filename),
                           lineNumber=getLineNumber(), 
                           routineName=getRoutineName(), 
                           moduleName=getModuleName(), 
                           errorClass="HDF5FileFormatError");            
        }

        if C_HDF5.H5Lexists(file_id, dsetName.c_str(), C_HDF5.H5P_DEFAULT) <= 0 {
            C_HDF5.H5Fclose(file_id);
            throw getErrorWithContext(
                 msg="The dataset %s does not exist in the file %s".format(dsetName, 
                                                filename),
                 lineNumber=getLineNumber(), 
                 routineName=getRoutineName(), 
                 moduleName=getModuleName(), 
                 errorClass='DatasetNotFoundError');
        }

        var objType: ObjType;
        var dataclass: C_HDF5.H5T_class_t;
        var bytesize: int;
        var isSigned: bool;
        try {
            objType = getObjType(file_id, dsetName);
            if objType == ObjType.STRINGS || objType == ObjType.SEGARRAY {
                if ( !calcStringOffsets ) {
                    var offsetDset = dsetName + "/" + SEGMENTED_OFFSET_NAME;
                    var (offsetClass, offsetByteSize, offsetSign) = 
                                            try get_dataset_info(file_id, offsetDset);
                    if (offsetClass != C_HDF5.H5T_INTEGER) {
                        throw getErrorWithContext(
                            msg="dataset %s has incorrect one or more sub-datasets" +
                            " %s %s".format(dsetName,SEGMENTED_OFFSET_NAME,SEGMENTED_VALUE_NAME), 
                            lineNumber=getLineNumber(),
                            routineName=getRoutineName(),
                            moduleName=getModuleName(),
                            errorClass='SegStringError');                    
                    }
                }
                var valueDset = dsetName + "/" + SEGMENTED_VALUE_NAME;
                try (dataclass, bytesize, isSigned) = 
                                           try get_dataset_info(file_id, valueDset);    
            } else if objType == ObjType.CATEGORICAL {
                (dataclass, bytesize, isSigned) = get_dataset_info(file_id, "%s/%s".format(dsetName, CODES_NAME));
            } else if objType == ObjType.GROUPBY {
                // for groupby this information will not be used, but needs to be returned for the workflow
                (dataclass, bytesize, isSigned) = get_dataset_info(file_id, "%s/%s".format(dsetName, PERMUTATION_NAME)); 
            } else {
                (dataclass, bytesize, isSigned) = get_dataset_info(file_id, dsetName);
            }
        } catch e : Error {
            //:TODO: recommend revisiting this catch block 
            throw getErrorWithContext( 
                msg="in get_info %s".format(e.message()), 
                lineNumber=getLineNumber(),
                routineName=getRoutineName(),
                moduleName=getModuleName(),
                errorClass='Error');
        }
        C_HDF5.H5Fclose(file_id);
        return (objType, dataclass, bytesize, isSigned);
    }

    proc assign_tags(A, filedomains: [?FD] domain(1), filenames: [FD] string, dsetName: string, skips: set(string)) throws {
        h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                "entry.a.targetLocales() = %t".format(A.targetLocales()));
        h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                "Filedomains: %t".format(filedomains));
        h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                "skips: %t".format(skips));

        coforall loc in A.targetLocales() do on loc {
            // Create local copies of args
            var locFiles = filenames;
            var locFiledoms = filedomains;
            /* On this locale, find all files containing data that belongs in
                this locale's chunk of A */
            for (filedom, filename, tag) in zip(locFiledoms, locFiles, 0..) {
                var isopen = false;
                var file_id: C_HDF5.hid_t;
                var dataset: C_HDF5.hid_t;

                if (skips.contains(filename)) {
                    h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                            "File %s does not contain data for this dataset, skipping".format(filename));
                } else {
                    // Look for overlap between A's local subdomains and this file
                    for locdom in A.localSubdomains() {
                        const intersection = domain_intersection(locdom, filedom);
                        if intersection.size > 0 {
                            A[intersection] = tag;
                        }
                    }
                }
            }
        }
    }

    proc generateTagData(filenames: [?fD] string, dset: string, 
                            objType: ObjType, validFiles: [] bool, st: borrowed SymTab) throws {
        var subdoms: [fD] domain(1);
        var skips = new set(string);
        var len: int;
        
        select objType {
            when ObjType.PDARRAY {
                (subdoms, len, skips) = get_subdoms(filenames, dset, validFiles);
            }
            when ObjType.STRINGS {
                (subdoms, len, skips) = get_subdoms(filenames, dset + "/" + SEGMENTED_OFFSET_NAME, validFiles);
            }
            when ObjType.SEGARRAY {
                (subdoms, len, skips) = get_subdoms(filenames, dset + "/" + SEGMENTED_OFFSET_NAME, validFiles);
            }
            when ObjType.ARRAYVIEW {
                var errorMsg = "ArrayView Objects do not support tagging";
                h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                throw getErrorWithContext(
                                    msg=errorMsg,
                                    lineNumber=getLineNumber(), 
                                    routineName=getRoutineName(), 
                                    moduleName=getModuleName(), 
                                    errorClass='UnhandledDatatypeError');
            }
            otherwise {
                var errorMsg = "Unknown object type found";
                h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                throw getErrorWithContext(
                                    msg=errorMsg,
                                    lineNumber=getLineNumber(), 
                                    routineName=getRoutineName(), 
                                    moduleName=getModuleName(), 
                                    errorClass='UnhandledDatatypeError');
            }
        }
        // create the tag entry
        var tagEntry = new shared SymEntry(len, int); // this will always contain integer values
        assign_tags(tagEntry.a, subdoms, filenames, dset, skips);
        var rname = st.nextName();
        st.addEntry(rname, tagEntry);
        return ("Filename_Codes", "pdarray", rname);
    }

    /*
        Read HDF5 files into an Arkouda Object
    */
    proc readAllHdfMsg(cmd: string, msgArgs: borrowed MessageArgs, st: borrowed SymTab): MsgTuple throws {
        var tagData: bool = msgArgs.get("tag_data").getBoolValue();
        var strictTypes: bool = msgArgs.get("strict_types").getBoolValue();

        var allowErrors: bool = msgArgs.get("allow_errors").getBoolValue(); // default is false
        if allowErrors {
            h5Logger.warn(getModuleName(), getRoutineName(), getLineNumber(), "Allowing file read errors");
        }

        var calcStringOffsets: bool = msgArgs.get("calc_string_offsets").getBoolValue(); // default is false
        if calcStringOffsets {
            h5Logger.warn(getModuleName(), getRoutineName(), getLineNumber(),
                "Calculating string array offsets instead of reading from HDF5");
        }

        var ndsets = msgArgs.get("dset_size").getIntValue();
        var dsetlist: [0..#ndsets] string;
        try {
            dsetlist = msgArgs.get("dsets").getList(ndsets);
        } catch {
            // limit length of dataset names to 2000 chars
            var n: int = 1000;
            var jsondsets = msgArgs.getValueOf("dsets");
            var dsets: string = if jsondsets.size > 2*n then jsondsets[0..#n]+'...'+jsondsets[jsondsets.size-n..#n] else jsondsets;
            var errorMsg = "Could not decode json dataset names via tempfile (%i files: %s)".format(
                                                ndsets, dsets);
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(errorMsg, MsgType.ERROR);
        }

        var nfiles = msgArgs.get("filename_size").getIntValue();
        var filelist: [0..#nfiles] string;
        try {
            filelist = msgArgs.get("filenames").getList(nfiles);
        } catch {
            // limit length of file names to 2000 chars
            var n: int = 1000;
            var jsonfiles = msgArgs.getValueOf("filenames");
            var files: string = if jsonfiles.size > 2*n then jsonfiles[0..#n]+'...'+jsonfiles[jsonfiles.size-n..#n] else jsonfiles;
            var errorMsg = "Could not decode json filenames via tempfile (%i files: %s)".format(nfiles, files);
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(errorMsg, MsgType.ERROR);
        }

        var filedom = filelist.domain;
        var filenames: [filedom] string;

        if filelist.size == 1 {
            if filelist[0].strip().size == 0 {
                var errorMsg = "filelist was empty.";
                h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                return new MsgTuple(errorMsg, MsgType.ERROR);
            }
            var tmp = glob(filelist[0]);
            h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                  "glob expanded %s to %i files".format(filelist[0], tmp.size));
            if tmp.size == 0 {
                var errorMsg = "The wildcarded filename %s either corresponds to files inaccessible to Arkouda or files of an invalid format".format(filelist[0]);
                h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                return new MsgTuple(errorMsg, MsgType.ERROR);
            }
            // Glob returns filenames in weird order. Sort for consistency
            sort(tmp);
            filedom = tmp.domain;
            filenames = tmp;
        } else {
            // assumes that we are providing 
            filenames = filelist;
        }
        
        var objTypeList: [filedom] ObjType;
        var dclasses: [filedom] C_HDF5.hid_t;
        var bytesizes: [filedom] int;
        var signFlags: [filedom] bool;
        var validFiles: [filedom] bool = true;
        var rtnData: list((string, string, string));
        var fileErrors: list(string);
        var fileErrorCount:int = 0;
        var fileErrorMsg:string = "";
        const AK_META_GROUP = ARKOUDA_HDF5_FILE_METADATA_GROUP(1..ARKOUDA_HDF5_FILE_METADATA_GROUP.size-1); // strip leading slash
        for dsetName in dsetlist do {
            if dsetName == AK_META_GROUP { // Legacy code to ignore meta group. Meta data no longer in group
                continue;
            }
            for (i, fname) in zip(filedom, filenames) {
                var hadError = false;
                try {
                    (objTypeList[i], dclasses[i], bytesizes[i], signFlags[i]) = get_info(fname, dsetName, calcStringOffsets);
                } catch e: FileNotFoundError {
                    fileErrorMsg = "File %s not found".format(fname);
                    h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),fileErrorMsg);
                    hadError = true;
                    if !allowErrors { return new MsgTuple(fileErrorMsg, MsgType.ERROR); }
                } catch e: PermissionError {
                    fileErrorMsg = "Permission error %s opening %s".format(e.message(),fname);
                    h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),fileErrorMsg);
                    hadError = true;
                    if !allowErrors { return new MsgTuple(fileErrorMsg, MsgType.ERROR); }
                } catch e: DatasetNotFoundError {
                    fileErrorMsg = "Dataset %s not found in file %s".format(dsetName,fname);
                    h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),fileErrorMsg);
                    hadError = true;
                    if !allowErrors { return new MsgTuple(fileErrorMsg, MsgType.ERROR); }
                } catch e: NotHDF5FileError {
                    fileErrorMsg = "The file %s is not an HDF5 file: %s".format(fname,e.message());
                    h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),fileErrorMsg);
                    hadError = true;
                    if !allowErrors { return new MsgTuple(fileErrorMsg, MsgType.ERROR); }
                } catch e: SegStringError {
                    fileErrorMsg = "SegmentedString error: %s".format(e.message());
                    h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),fileErrorMsg);
                    hadError = true;
                    if !allowErrors { return new MsgTuple(fileErrorMsg, MsgType.ERROR); }
                } catch e : Error {
                    fileErrorMsg = "Other error in accessing file %s: %s".format(fname,e.message());
                    h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),fileErrorMsg);
                    hadError = true;
                    if !allowErrors { return new MsgTuple(fileErrorMsg, MsgType.ERROR); }
                }

                if hadError {
                    // Keep running total, but we'll only report back the first 10
                    if fileErrorCount < 10 {
                        fileErrors.pushBack(fileErrorMsg.replace("\n", " ").replace("\r", " ").replace("\t", " ").strip());
                    }
                    fileErrorCount += 1;
                    validFiles[i] = false;
                }
            }
            
            // identify the index of the first valid file
            var (v, idx) = maxloc reduce zip(validFiles, validFiles.domain);
            const objType = objTypeList[idx];
            const dataclass = dclasses[idx];
            const bytesize = bytesizes[idx];
            const isSigned = signFlags[idx];
            for (isValid, name, ot, dc, bs, sf) in zip(validFiles, filenames, objTypeList, dclasses, bytesizes, signFlags) {
                if isValid {
                    if (ot != objType) {
                        var errorMsg = "Inconsistent objecttype in dataset %s of file %s. Expected: %s, Found: %s".format(dsetName, name, objType:string, ot:string);
                        h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                        return new MsgTuple(errorMsg, MsgType.ERROR);
                    }
                    else if (dc != dataclass) {
                        var errorMsg = "Inconsistent dtype in dataset %s of file %s".format(dsetName, name);
                        h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                        return new MsgTuple(errorMsg, MsgType.ERROR);
                    } else if (strictTypes && ((bs != bytesize) || (sf != isSigned))) {
                        var errorMsg = "Inconsistent precision or sign in dataset %s of file %s\nWith strictTypes, mixing of precision and signedness not allowed (set strictTypes=False to suppress)".format(dsetName, name);
                        h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                        return new MsgTuple(errorMsg, MsgType.ERROR);
                    }
                }
            }
            h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                                           "Verified all dtypes across files for dataset %s".format(dsetName));

            if tagData {
                h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(), "Tagging Data with File Code");
                rtnData.pushBack(generateTagData(filenames, dsetName, objType, validFiles, st));
                tagData = false; // turn off so we only run once
            }

            select objType {
                when ObjType.ARRAYVIEW {
                    rtnData.pushBack(arrayView_readhdfMsg(filenames, dsetName, dataclass, bytesize, isSigned, validFiles, st));
                }
                when ObjType.PDARRAY {
                    rtnData.pushBack(pdarray_readhdfMsg(filenames, dsetName, dataclass, bytesize, isSigned, validFiles, st));
                }
                when ObjType.STRINGS {
                    rtnData.pushBack(strings_readhdfMsg(filenames, dsetName, dataclass, bytesize, isSigned, calcStringOffsets, validFiles, st));
                }
                when ObjType.SEGARRAY {
                    rtnData.pushBack(segarray_readhdfMsg(filenames, dsetName, dataclass, bytesize, isSigned, validFiles, st));
                }
                when ObjType.CATEGORICAL {
                    rtnData.pushBack(categorical_readhdfMsg(filenames, dsetName, validFiles, calcStringOffsets, st));
                }
                when ObjType.GROUPBY {
                    rtnData.pushBack(groupby_readhdfMsg(filenames, dsetName, validFiles, calcStringOffsets, st));
                }
                otherwise {
                    var errorMsg = "Unknown object type found";
                    h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                    return new MsgTuple(errorMsg, MsgType.ERROR);
                }
            }
        }
        if allowErrors && fileErrorCount > 0 {
            h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                "allowErrors:true, fileErrorCount:%t".format(fileErrorCount));
        }
        var repMsg: string = _buildReadAllMsgJson(rtnData, allowErrors, fileErrorCount, fileErrors, st);
        h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),repMsg);
        return new MsgTuple(repMsg,MsgType.NORMAL);
    }

    proc hdfFileFormatMsg(cmd: string, msgArgs: borrowed MessageArgs, st: borrowed SymTab): MsgTuple throws {
        var repMsg: string;

        // Retrieve filename from payload
        var filename: string = msgArgs.getValueOf("filename");
        if filename.isEmpty() {
            var errorMsg = "Filename was Empty";
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(errorMsg, MsgType.ERROR);
        }

        // If the filename represents a glob pattern, retrieve the locale 0 filename
        if isGlobPattern(filename) {
            // Attempt to interpret filename as a glob expression and ls the first result
            var tmp = glob(filename);
            h5Logger.debug(getModuleName(),getRoutineName(),getLineNumber(),
                      "glob-expanded filename: %s to size: %i files".format(filename, tmp.size));

            if tmp.size <= 0 {
                var errorMsg = "Cannot retrieve filename from glob expression %s, check file name or format".format(filename);
                h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
                return new MsgTuple(errorMsg, MsgType.ERROR);
            }
            
            // Set filename to globbed filename corresponding to locale 0
            filename = tmp[tmp.domain.first];
        }
        
        // Check to see if the file exists. If not, return an error message
        if !exists(filename) {
            var errorMsg = "File %s does not exist in a location accessible to Arkouda".format(filename);
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(errorMsg,MsgType.ERROR);
        } 

        if !isHdf5File(filename) {
            var errorMsg = "File %s is not an HDF5 file".format(filename);
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(errorMsg,MsgType.ERROR);
        }
        
        try {
            var file_id = C_HDF5.H5Fopen(filename.c_str(), C_HDF5.H5F_ACC_RDONLY, C_HDF5.H5P_DEFAULT);
            defer { C_HDF5.H5Fclose(file_id); } // ensure file is closed
            if C_HDF5.H5Aexists_by_name(file_id, ".".c_str(), "File_Format", C_HDF5.H5P_DEFAULT) > 0 {
                var file_format_id: C_HDF5.hid_t = C_HDF5.H5Aopen_by_name(file_id, ".".c_str(), "File_Format", C_HDF5.H5P_DEFAULT, C_HDF5.H5P_DEFAULT);
                var file_format: int;
                C_HDF5.H5Aread(file_format_id, getHDF5Type(int), c_ptrTo(file_format));
                C_HDF5.H5Aclose(file_format_id);
                
                // convert integer to string
                if file_format == 0 {
                    repMsg = "single";
                }
                else if file_format == 1 {
                    repMsg = "distribute";
                }
                else {
                    throw getErrorWithContext(
                            msg="Unknown file formatting, %i.".format(file_format),
                            lineNumber=getLineNumber(),
                            routineName=getRoutineName(), 
                            moduleName=getModuleName(),
                            errorClass="IllegalArgumentError");
                }
            }
            else{
                // generate regex to match distributed filename
                var dist_regex = compile("_LOCALE\\d{4}");

                if dist_regex.search(filename){
                    repMsg = "distribute";
                }
                else {
                    repMsg = "single";
                }
            }
        } catch e : Error {
            var errorMsg = "Failed to process HDF5 file %t".format(e.message());
            h5Logger.error(getModuleName(),getRoutineName(),getLineNumber(),errorMsg);
            return new MsgTuple(errorMsg, MsgType.ERROR);
        }

        return new MsgTuple(repMsg, MsgType.NORMAL);
    }

    use CommandMap;
    registerFunction("lshdf", lshdfMsg, getModuleName());
    registerFunction("readAllHdf", readAllHdfMsg, getModuleName());
    registerFunction("tohdf", tohdfMsg, getModuleName());
    registerFunction("hdffileformat", hdfFileFormatMsg, getModuleName());
}
