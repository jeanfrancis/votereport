require 'active_record'
require 'geo_ruby'
require 'common_spatial_adapter'

include GeoRuby::SimpleFeatures

#tables to ignore in migration : relative to PostGIS management of geometric columns
ActiveRecord::SchemaDumper.ignore_tables << "spatial_ref_sys" << "geometry_columns"


#add a method to_yaml to the Geometry class which will transform a geometry in a form suitable to be used in a YAML file (such as in a fixture)
GeoRuby::SimpleFeatures::Geometry.class_eval do
  def to_fixture_format
    as_hex_ewkb
  end
end


ActiveRecord::Base.class_eval do
  require 'active_record/version'

  #For Rails < 1.2
  if ActiveRecord::VERSION::STRING < "1.15.1"
    def self.construct_conditions_from_arguments(attribute_names, arguments)
      conditions = []
      attribute_names.each_with_index do |name, idx| 
        if columns_hash[name].is_a?(SpatialColumn)
          #when the discriminating column is spatial, always use the && (bounding box intersection check) operator : the user can pass either a geometric object (which will be transformed to a string using the quote method of the database adapter) or an array representing 2 opposite corners of a bounding box
          if arguments[idx].is_a?(Array)
            bbox = arguments[idx]
            conditions << "#{table_name}.#{connection.quote_column_name(name)} && SetSRID(?::box3d, #{bbox[2] || DEFAULT_SRID} ) " 
            #Could do without the ? and replace directly with the quoted BBOX3D but like this, the flow is the same everytime
            arguments[idx]= "BOX3D(" + bbox[0].join(" ") + "," + bbox[1].join(" ") + ")"
          else
            conditions << "#{table_name}.#{connection.quote_column_name(name)} && ? " 
          end
        else
          conditions << "#{table_name}.#{connection.quote_column_name(name)} #{attribute_condition(arguments[idx])} " 
        end
      end
      [ conditions.join(" AND "), *arguments[0...attribute_names.length] ]
    end
  else
    def self.get_conditions(attrs)
      attrs.map do |attr, value|
        if columns_hash[attr].is_a?(SpatialColumn)
          if value.is_a?(Array)
            attrs[attr]= "BOX3D(" + value[0].join(" ") + "," + value[1].join(" ") + ")"
            "#{table_name}.#{connection.quote_column_name(attr)} && SetSRID(?::box3d, #{value[2] || DEFAULT_SRID} ) " 
          elsif value.is_a?(Envelope)
            attrs[attr]= "BOX3D(" + value.lower_corner.text_representation + "," + value.upper_corner.text_representation + ")"
            "#{table_name}.#{connection.quote_column_name(attr)} && SetSRID(?::box3d, #{value.srid} ) " 
          else
            "#{table_name}.#{connection.quote_column_name(attr)} && ? " 
          end
        else
          "#{table_name}.#{connection.quote_column_name(attr)} #{attribute_condition(value)}"
        end
      end.join(' AND ')
    end
    if ActiveRecord::VERSION::STRING == "1.15.1"
      def self.sanitize_sql_hash(attrs)
        conditions = get_conditions(attrs)
        replace_bind_variables(conditions, attrs.values)
      end
    else
      def self.sanitize_sql_hash(attrs)
        conditions = get_conditions(attrs)
        replace_bind_variables(conditions, expand_range_bind_variables(attrs.values))
      end
    end
  end
end

ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.class_eval do

  include SpatialAdapter

  alias :original_native_database_types :native_database_types
  def native_database_types
    original_native_database_types.merge!(geometry_data_types)
  end

  alias :original_quote :quote
  #Redefines the quote method to add behaviour for when a Geometry is encountered
  def quote(value, column = nil)
    if value.kind_of?(GeoRuby::SimpleFeatures::Geometry)
      "'#{value.as_hex_ewkb}'"
    else
      original_quote(value,column)
    end
  end

  def create_table(name, options = {})
    table_definition = ActiveRecord::ConnectionAdapters::PostgreSQLTableDefinition.new(self)
    table_definition.primary_key(options[:primary_key] || "id") unless options[:id] == false
    
    yield table_definition
    
    if options[:force]
      drop_table(name) rescue nil
    end
    
    create_sql = "CREATE#{' TEMPORARY' if options[:temporary]} TABLE "
    create_sql << "#{name} ("
    create_sql << table_definition.to_sql
    create_sql << ") #{options[:options]}"
    execute create_sql
    
    #added to create the geometric columns identified during the table definition
    unless table_definition.geom_columns.nil?
      table_definition.geom_columns.each do |geom_column|
        execute geom_column.to_sql(name)
      end
    end
  end
  
  alias :original_remove_column :remove_column
  def remove_column(table_name,column_name)
    columns(table_name).each do |col|
      if col.name == column_name.to_s 
        #check if the column is geometric
        unless geometry_data_types[col.type].nil?
          execute "SELECT DropGeometryColumn('#{table_name}','#{column_name}')"
        else
          original_remove_column(table_name,column_name)
        end
      end
    end
  end
  
  alias :original_add_column :add_column
  def add_column(table_name, column_name, type, options = {})
    unless geometry_data_types[type].nil?
      geom_column = ActiveRecord::ConnectionAdapters::PostgreSQLColumnDefinition.new(self,column_name, type, nil,nil,options[:null],options[:srid] || -1 , options[:with_z] || false , options[:with_m] || false)
      execute geom_column.to_sql(table_name)
    else
      original_add_column(table_name,column_name,type,options)
    end
  end
  
  
  
  #Adds a GIST spatial index to a column. Its name will be <table_name>_<column_name>_spatial_index unless the key :name is present in the options hash, in which case its value is taken as the name of the index.
  def add_index(table_name,column_name,options = {})
    index_name = options[:name] || index_name(table_name,:column => Array(column_name))
    if options[:spatial]
      execute "CREATE INDEX #{index_name} ON #{table_name} USING GIST (#{Array(column_name).join(", ")} GIST_GEOMETRY_OPS)"
    else
      index_type = options[:unique] ? "UNIQUE" : ""
      #all together
      execute "CREATE #{index_type} INDEX #{index_name} ON #{table_name} (#{Array(column_name).join(", ")})"
    end
  end
  
      
  def indexes(table_name, name = nil) #:nodoc:
    result = query(<<-SQL, name)
          SELECT i.relname, d.indisunique, a.attname , am.amname
            FROM pg_class t, pg_class i, pg_index d, pg_attribute a, pg_am am
           WHERE i.relkind = 'i'
             AND d.indexrelid = i.oid
             AND d.indisprimary = 'f'
             AND t.oid = d.indrelid
             AND i.relam = am.oid
             AND t.relname = '#{table_name}'
             AND a.attrelid = t.oid
             AND ( d.indkey[0]=a.attnum OR d.indkey[1]=a.attnum
                OR d.indkey[2]=a.attnum OR d.indkey[3]=a.attnum
                OR d.indkey[4]=a.attnum OR d.indkey[5]=a.attnum
                OR d.indkey[6]=a.attnum OR d.indkey[7]=a.attnum
                OR d.indkey[8]=a.attnum OR d.indkey[9]=a.attnum )
          ORDER BY i.relname
        SQL

    current_index = nil
    indexes = []
    
    result.each do |row|
      if current_index != row[0]
        indexes << ActiveRecord::ConnectionAdapters::IndexDefinition.new(table_name, row[0], row[1] == "t", row[3] == "gist" ,[]) #index type gist indicates a spatial index (probably not totally true but let's simplify!)
        current_index = row[0]
      end
      
      indexes.last.columns << row[2]
    end
    
    indexes
  end
      
  def columns(table_name, name = nil) #:nodoc:
    raw_geom_infos = column_spatial_info(table_name)
    
    column_definitions(table_name).collect do |name, type, default, notnull|
      if type =~ /geometry/i and raw_geom_infos[name]
        raw_geom_info = raw_geom_infos[name]
        
        ActiveRecord::ConnectionAdapters::SpatialPostgreSQLColumn.new(name,default_value(default),raw_geom_info.type,notnull == "f",raw_geom_info.srid,raw_geom_info.with_z,raw_geom_info.with_m)
      else
        ActiveRecord::ConnectionAdapters::Column.new(name, default_value(default), translate_field_type(type),notnull == "f")
      end
    end
  end
      
  private
         
  def column_spatial_info(table_name)
    constr = query <<-end_sql
    SELECT pg_get_constraintdef(oid) 
    FROM pg_constraint
    WHERE conrelid = '#{table_name}'::regclass
    AND contype = 'c'
    end_sql
    
    raw_geom_infos = {}
    constr.each do |constr_def_a|
      constr_def = constr_def_a[0] #only 1 column in the result
      if constr_def =~ /geometrytype\(["']?([^"')]+)["']?\)\s*=\s*'([^']+)'/i
        column_name,type = $1,$2
        if type[-1] == ?M
          with_m = true
          type.chop!
        else
          with_m = false
        end
        raw_geom_info = raw_geom_infos[column_name] || ActiveRecord::ConnectionAdapters::RawGeomInfo.new
        raw_geom_info.type = type
        raw_geom_info.with_m = with_m
        raw_geom_infos[column_name] = raw_geom_info
      elsif constr_def =~ /ndims\(["']?([^"')]+)["']?\)\s*=\s*(\d+)/i
        column_name,dimension = $1,$2
        raw_geom_info = raw_geom_infos[column_name] || ActiveRecord::ConnectionAdapters::RawGeomInfo.new
        raw_geom_info.dimension = dimension.to_i
        raw_geom_infos[column_name] = raw_geom_info
      elsif constr_def =~ /srid\(["']?([^"')]+)["']?\)\s*=\s*(-?\d+)/i
        column_name,srid = $1,$2
        raw_geom_info = raw_geom_infos[column_name] || ActiveRecord::ConnectionAdapters::RawGeomInfo.new
        raw_geom_info.srid = srid.to_i
        raw_geom_infos[column_name] = raw_geom_info
      end #if constr_def
    end #constr.each

    raw_geom_infos.each_value do |raw_geom_info|
      #check the presence of z and m
      raw_geom_info.convert!
    end

    raw_geom_infos

  end
  
end

module ActiveRecord
  module ConnectionAdapters
    class RawGeomInfo < Struct.new(:type,:srid,:dimension,:with_z,:with_m) #:nodoc:
      def convert!
        self.type = "geometry" if self.type.nil? #if geometry the geometrytype constraint is not present : need to set the type here then
        
        if dimension == 4
          self.with_m = true
          self.with_z = true
        elsif dimension == 3
          if with_m
            self.with_z = false
            self.with_m = true 
          else
            self.with_z = true
            self.with_m = false
          end
        else
          self.with_z = false
          self.with_m = false
        end
      end
    end
  end
end


module ActiveRecord
  module ConnectionAdapters
    class PostgreSQLTableDefinition < TableDefinition
      attr_reader :geom_columns
      
      def column(name, type, options = {})
        unless @base.geometry_data_types[type].nil?
          geom_column = PostgreSQLColumnDefinition.new(@base,name, type)
          geom_column.null = options[:null]
          geom_column.srid = options[:srid] || -1
          geom_column.with_z = options[:with_z] || false 
          geom_column.with_m = options[:with_m] || false
         
          @geom_columns = [] if @geom_columns.nil?
          @geom_columns << geom_column          
        else
          super(name,type,options)
        end
      end
    end

    class PostgreSQLColumnDefinition < ColumnDefinition
      attr_accessor :srid, :with_z,:with_m
      attr_reader :spatial

      def initialize(base = nil, name = nil, type=nil, limit=nil, default=nil,null=nil,srid=-1,with_z=false,with_m=false)
        super(base, name, type, limit, default,null)
        @spatial=true
        @srid=srid
        @with_z=with_z
        @with_m=with_m
      end
      
      def to_sql(table_name)
        if @spatial
          type_sql = type_to_sql(type.to_sym)
          type_sql += "M" if with_m and !with_z
          if with_m and with_z
            dimension = 4 
          elsif with_m or with_z
            dimension = 3
          else
            dimension = 2
          end
          
          column_sql = "SELECT AddGeometryColumn('#{table_name}','#{name}',#{srid},'#{type_sql}',#{dimension})"
          column_sql += ";ALTER TABLE #{table_name} ALTER #{name} SET NOT NULL" if null == false
          column_sql
        else
          super
        end
      end
  
  
      private
      def type_to_sql(name, limit=nil)
        base.type_to_sql(name, limit) rescue name
      end   
      
    end

  end
end

#Would prefer creation of a PostgreSQLColumn type instead but I would need to reimplement methods where Column objects are instantiated so I leave it like this
module ActiveRecord
  module ConnectionAdapters
    class SpatialPostgreSQLColumn < Column

      include SpatialColumn
      
      #Transforms a string to a geometry. PostGIS returns a HewEWKB string.
      def self.string_to_geometry(string)
        return string unless string.is_a?(String)
        GeoRuby::SimpleFeatures::Geometry.from_hex_ewkb(string) rescue nil
      end
    end
  end
end
